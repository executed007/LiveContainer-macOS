import Foundation

/// Installs a decrypted iOS app (.ipa or .app) into LiveContainer.
///
/// Like upstream LiveContainer, the app is not turned into a separate Mac app: it is stored
/// in Documents/Applications and its executable is patched so the runtime can dlopen it.
/// The Mac-specific steps come from Catalyst Runner (and PlayCover before it): every binary
/// is thinned to arm64 and retargeted to Mac Catalyst, and signed ad hoc, because Apple
/// silicon only runs signed code.
///
/// Reinstalling (an update) keeps the app's containers, keychain and settings.
struct Installer {
    struct Options {
        /// Leave binaries as iOS binaries and rely on the runtime's dyld patch instead.
        var keepIOSPlatform = false
        /// Inject TweakLoader into the executable (upstream's default).
        var injectTweakLoader = true
    }

    enum Failure: Error, CustomStringConvertible {
        case noAppInPayload, missingInfo(String), tool(String, Int32, String), running(String), notExecutable(String)

        var description: String {
            switch self {
            case .noAppInPayload: "no .app found in the archive's Payload folder"
            case .missingInfo(let key): "Info.plist is missing \(key)"
            case .tool(let path, let status, let output): "\(path) exited with \(status): \(output)"
            case .running(let name): "\(name) is running; quit it before updating"
            case .notExecutable(let name): "\(name) has no main entry point, so it is not an app executable"
            }
        }
    }

    /// iOS apps get Mac camera effects (Portrait, reactions, Studio Light) whose teardown
    /// crashes inside system frameworks; opt out, as Catalyst Runner does.
    static let cameraEffectKeys = [
        "NSCameraPortraitEffectEnabled", "NSCameraBackgroundReplacementEnabled", "NSCameraStudioLightEnabled",
        "NSCameraReactionEffectsEnabled", "NSCameraReactionEffectGesturesEnabledDefault",
    ]

    var library = LCLibrary()
    var options = Options()
    var launchers: Launchers { Launchers(paths: library.paths) }
    /// Progress messages, in order. Called on the installing thread.
    var log: (String) -> Void = { print($0) }
    private let files = FileManager.default

    @discardableResult
    func install(_ source: URL) throws -> LCApp {
        let paths = library.paths
        try paths.createFolders()
        let scratch = files.temporaryDirectory.appendingPathComponent("livecontainer-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        var bundle = source
        if source.pathExtension.lowercased() == "ipa" {
            log("Extracting app from .ipa file...")
            try Shell.run("/usr/bin/ditto", ["-x", "-k", source.path, scratch.path])
            let payload = scratch.appendingPathComponent("Payload")
            let apps = (try? files.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw Failure.noAppInPayload }
            bundle = app
        }

        let info = LCPlist.read(bundle.appendingPathComponent("Info.plist"))
        guard let identifier = info["CFBundleIdentifier"] as? String else { throw Failure.missingInfo("CFBundleIdentifier") }
        guard let executable = info["CFBundleExecutable"] as? String else { throw Failure.missingInfo("CFBundleExecutable") }
        let folderName = "\(identifier).app"
        let destination = paths.applications.appendingPathComponent(folderName)
        let previous = LCApp(url: destination, paths: paths)
        if files.fileExists(atPath: destination.path), previous.isRunning { throw Failure.running(previous.displayName) }

        // Work on a private copy so a failure never leaves a half-installed app.
        log("Copying app...")
        let staged = scratch.appendingPathComponent("staged/\(folderName)")
        try files.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        if bundle.path.hasPrefix(scratch.path) {
            try files.moveItem(at: bundle, to: staged)
        } else {
            try Shell.run("/bin/cp", ["-cR", bundle.path, staged.path])    // APFS clone: instant, no extra space
        }
        // Watch apps are built for watchOS and can never run here.
        try? files.removeItem(at: staged.appendingPathComponent("Watch"))

        let infoURL = staged.appendingPathComponent("Info.plist")
        var edited = LCPlist.read(infoURL)
        for key in Installer.cameraEffectKeys { edited[key] = false }
        try LCPlist.write(edited, to: infoURL)

        var binaries = try machOFiles(in: staged)
        guard let main = binaries.first(where: {
            $0.lastPathComponent == executable && $0.deletingLastPathComponent().lastPathComponent == staged.lastPathComponent
        }) else { throw Failure.missingInfo("a Mach-O at \(executable)") }

        log(options.keepIOSPlatform ? "Preparing \(binaries.count) binaries..." : "Converting \(binaries.count) binaries to Mac Catalyst...")
        var skipped: [URL] = []
        let lock = NSLock()
        var firstError: Error?
        DispatchQueue.concurrentPerform(iterations: binaries.count) { index in
            let binary = binaries[index]
            do {
                let thin = try MachO.thinned(try Data(contentsOf: binary))
                if try MachO.isEncrypted(thin) { throw MachO.Failure.encrypted }
                let converted = options.keepIOSPlatform ? thin : try MachO.replacingVersionCommand(thin)
                try converted.write(to: binary)     // non-atomic: keeps the executable bit
            } catch MachO.Failure.noArm64Slice where binary != main {
                lock.lock(); skipped.append(binary); lock.unlock()
            } catch {
                lock.lock(); firstError = firstError ?? error; lock.unlock()
            }
        }
        if let firstError { throw firstError }
        for binary in skipped {
            log("Removing \(relative(binary, to: staged)): it has no arm64 code")
            try? files.removeItem(at: binary)
        }
        binaries.removeAll { skipped.contains($0) }

        log("Patching executable...")
        let previousInfo = files.fileExists(atPath: destination.path) ? previous.appInfo : [:]
        let inject = !(previousInfo["dontInjectTweakLoader"] as? Bool ?? !options.injectTweakLoader)
        let thinMain = try Data(contentsOf: main)
        guard MachO.hasMainEntryPoint(thinMain) else { throw Failure.notExecutable(executable) }
        let (patched, patchResult) = try MachO.patchedForLiveContainer(thinMain, name: executable, injectTweakLoader: inject)
        try patched.write(to: main)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path)
        if patchResult.contains(.noSpaceForTweakLoader) {
            log("No room in the executable for TweakLoader; tweaks are off for this app")
        }

        log("Signing...")
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try Installer.sign(binaries, in: staged)

        log("Adding app to LiveContainer...")
        var appInfo = previousInfo
        appInfo["LCOrignalBundleIdentifier"] = identifier
        appInfo["LCMacConverted"] = !options.keepIOSPlatform
        appInfo["LCMacDisplayName"] = edited["CFBundleDisplayName"] ?? edited["CFBundleName"] ?? identifier
        appInfo["installationDate"] = Date()
        appInfo["segCountMismatch"] = patchResult.contains(.segCountMismatch)
        appInfo["LCTweakLoaderCantInject"] = patchResult.contains(.noSpaceForTweakLoader)
        appInfo["dontInjectTweakLoader"] = !inject
        appInfo["LCPatchRevision"] = 1
        // Upstream's rule: without the load command, tweaks cannot be loaded for this app.
        if patchResult.contains(.noSpaceForTweakLoader) { appInfo["dontInjectTweakLoader"] = true; appInfo["dontLoadTweakLoader"] = true }
        try LCPlist.write(appInfo, to: staged.appendingPathComponent("LCAppInfo.plist"))
        for keep in ["LCMacSettings.plist"] {
            let old = destination.appendingPathComponent(keep)
            if files.fileExists(atPath: old.path) { try files.copyItem(at: old, to: staged.appendingPathComponent(keep)) }
        }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: staged, to: destination)

        let app = LCApp(url: destination, paths: paths)
        if app.containers.isEmpty {
            try library.addContainer(to: app, name: "Default")
        }
        for container in app.containers { try LCLibrary.makeContainerFolders(container.url) }

        log("Making Mac launcher...")
        try? files.removeItem(at: launchers.url(for: app).appendingPathComponent("Contents/Resources/AppIcon.icns"))
        try launchers.make(for: app, iconSource: destination, scratch: scratch)
        return app
    }

    /// Moves an app to the Trash. Its containers are kept unless `deleteData`.
    func uninstall(_ app: LCApp, deleteData: Bool) throws {
        guard !app.isRunning else { throw Failure.running(app.displayName) }
        let containers = app.containers
        launchers.remove(for: app)
        try library.paths.discard(app.url)
        if deleteData {
            for container in containers { try library.paths.discard(container.url) }
        }
    }

    /// Imports a tweak (dylib or framework) into the global Tweaks folder or a tweak set.
    /// iOS tweaks are retargeted to Mac Catalyst and signed, so they load without the dyld patch.
    @discardableResult
    func importTweak(_ source: URL, folder: String? = nil) throws -> URL {
        let paths = library.paths
        let target = folder.map { paths.tweaks.appendingPathComponent($0) } ?? paths.tweaks
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = target.appendingPathComponent(source.lastPathComponent)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try Shell.run("/bin/cp", ["-cR", source.path, destination.path])
        let binaries = try machOFiles(in: destination)
        for binary in binaries {
            let thin = try MachO.thinned(try Data(contentsOf: binary))
            try MachO.replacingVersionCommand(thin).write(to: binary)
        }
        try Installer.sign(binaries, in: destination)
        return destination
    }

    // MARK: - Signing

    /// Signs every binary ad hoc, innermost bundles first. Binaries at the same depth do not
    /// depend on each other, so each level is signed in parallel: on an app with dozens of
    /// frameworks this is several times faster than signing one after another.
    static func sign(_ binaries: [URL], in root: URL) throws {
        var targets: [URL] = []
        for binary in binaries {
            let parent = binary.deletingLastPathComponent()
            let isBundleExecutable = ["framework", "appex", "xctest", "bundle"].contains(parent.pathExtension)
                && parent.deletingPathExtension().lastPathComponent == binary.lastPathComponent
            let target = isBundleExecutable ? parent : binary
            if !targets.contains(target) { targets.append(target) }
        }
        let levels = Dictionary(grouping: targets) { $0.pathComponents.count }.sorted { $0.key > $1.key }
        for (_, level) in levels {
            let lock = NSLock()
            var failure: Error?
            DispatchQueue.concurrentPerform(iterations: level.count) { index in
                do {
                    try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", level[index].path])
                } catch {
                    lock.lock(); failure = failure ?? error; lock.unlock()
                }
            }
            if let failure { throw failure }
        }
    }

    // MARK: - Helpers

    private func relative(_ url: URL, to root: URL) -> String {
        url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    func machOFiles(in bundle: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: bundle.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return [bundle]
        }
        guard let walker = files.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: MachO.headerSize)) ?? Data()
            try? handle.close()
            if MachO.isMachO(head) { result.append(url.standardizedFileURL) }
        }
        return result
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Installer.Failure.tool(path, process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
