import AppKit
import CryptoKit
import Foundation

/// Each installed app gets a launcher: a tiny Mac Catalyst app (macOS/Runtime/launcher.c)
/// with the app's name, icon, URL schemes and permission texts, and no app code. Opening it
/// loads LiveContainer's runtime, which runs the real app from Documents/Applications.
///
/// This is how a Mac gets what iOS LiveContainer cannot have: every app in its own process
/// and Dock icon, several apps (or several containers of one app) running at once, URL
/// schemes and OAuth callbacks routed to the right app by macOS, and real Launchpad,
/// Spotlight and Finder "Open With" entries once added to Applications.
///
/// macOS ties camera, microphone and other permissions to the launcher's signature. A
/// launcher is therefore only rewritten when something it shows changes, and it leaves out
/// per-version keys, so updating an app does not make macOS ask for permissions again.
struct Launchers {
    var paths = LCPaths()

    static let bundlePrefix = "com.kdt.livecontainer.mac.app."
    static let runtimeName = "LiveContainerMac.dylib"
    static let templateName = "LCLauncher"

    /// Guest Info.plist keys that make no sense for a Mac launcher, or that change on every
    /// update and would invalidate permissions for nothing.
    static let droppedKeys: Set<String> = [
        "CFBundleIcons", "CFBundleIcons~ipad", "CFBundleIconFiles", "CFBundleIconName", "LSRequiresIPhoneOS",
        "UIRequiredDeviceCapabilities", "MinimumOSVersion", "UIApplicationShortcutItems", "NSExtension",
        "UTExportedTypeDeclarations", "CFBundleShortVersionString", "CFBundleVersion", "BuildMachineOSBuild",
        "DTCompiler", "DTPlatformBuild", "DTPlatformName", "DTPlatformVersion", "DTSDKBuild", "DTSDKName",
        "DTXcode", "DTXcodeBuild", "DTAppStoreToolsBuild", "UILaunchStoryboardName", "UILaunchScreen",
        "CFBundleSupportedPlatforms", "UISupportedDevices", "UIBackgroundModes", "WKCompanionAppBundleIdentifier",
    ]

    /// The runtime and launcher template shipped with this copy of LiveContainer.
    static var runtimeFolder: URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["LC_MAC_RUNTIME"] {
            candidates.append(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        if let frameworks = Bundle.main.privateFrameworksURL { candidates.append(frameworks) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates += [executable, executable.deletingLastPathComponent().appendingPathComponent("Frameworks")]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(runtimeName).path) }
    }

    func bundleIdentifier(for app: LCApp) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let clean = String(app.bundleIdentifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return Launchers.bundlePrefix + clean
    }

    /// Where the app's launcher is: in Applications if it was added there, else in LiveContainer.
    func url(for app: LCApp) -> URL {
        if let path = app.appInfo["LCMacLauncherPath"] as? String { return URL(fileURLWithPath: path) }
        return paths.launchers.appendingPathComponent(app.folderName)
    }

    func isInApplications(_ app: LCApp) -> Bool { app.appInfo["LCMacLauncherPath"] != nil }

    /// Writes (or refreshes) the launcher. Does nothing when it is already up to date.
    func make(for app: LCApp, iconSource: URL? = nil, scratch: URL? = nil) throws {
        guard let runtime = Launchers.runtimeFolder else {
            throw LCError.message("LiveContainer's runtime (\(Launchers.runtimeName)) was not found next to this program")
        }
        let launcher = url(for: app)
        let contents = launcher.appendingPathComponent("Contents")
        let guestInfo = app.info
        let executable = sanitizedName(guestInfo["CFBundleExecutable"] as? String ?? "App")

        var info = guestInfo.filter { !Launchers.droppedKeys.contains($0.key) }
        info["CFBundleIdentifier"] = bundleIdentifier(for: app)
        info["CFBundleExecutable"] = executable
        info["CFBundlePackageType"] = "APPL"
        info["CFBundleName"] = guestInfo["CFBundleName"] ?? app.displayName
        info["CFBundleDisplayName"] = app.displayName
        info["CFBundleShortVersionString"] = "1.0"
        info["CFBundleVersion"] = "1"
        info["CFBundleSupportedPlatforms"] = ["MacOSX"]
        info["LSMinimumSystemVersion"] = "14.0"
        info["NSHighResolutionCapable"] = true
        info["CFBundleIconFile"] = "AppIcon"
        if info["LSApplicationCategoryType"] == nil { info["LSApplicationCategoryType"] = "public.app-category.entertainment" }
        for key in Installer.cameraEffectKeys { info[key] = false }
        info["LCGuestApp"] = app.folderName
        info["LCMacRuntime"] = runtime.appendingPathComponent(Launchers.runtimeName).path
        if !paths.isDefault { info["LCHomePath"] = paths.home.path }

        let template = runtime.appendingPathComponent(Launchers.templateName)
        let templateHash = try SHA256.hash(data: Data(contentsOf: template)).map { String(format: "%02x", $0) }.joined()
        info["LCMacLauncherBuild"] = templateHash

        let infoURL = contents.appendingPathComponent("Info.plist")
        let icon = contents.appendingPathComponent("Resources/AppIcon.icns")
        let fm = FileManager.default
        if NSDictionary(dictionary: LCPlist.read(infoURL)).isEqual(to: info),
           fm.fileExists(atPath: contents.appendingPathComponent("MacOS/\(executable)").path),
           fm.fileExists(atPath: icon.path) {
            return
        }

        // Build next to the old launcher and swap it in, so it is never missing while in use.
        let staged = launcher.deletingLastPathComponent().appendingPathComponent(".\(launcher.lastPathComponent).\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        let stagedContents = staged.appendingPathComponent("Contents")
        let stagedIcon = stagedContents.appendingPathComponent("Resources/AppIcon.icns")
        try fm.createDirectory(at: stagedContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stagedContents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: stagedContents.appendingPathComponent("MacOS/\(executable)"))
        try Data("APPL????".utf8).write(to: stagedContents.appendingPathComponent("PkgInfo"))

        let work = scratch ?? fm.temporaryDirectory.appendingPathComponent("livecontainer-icon-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if scratch == nil { try? fm.removeItem(at: work) } }
        if fm.fileExists(atPath: icon.path) {
            try fm.copyItem(at: icon, to: stagedIcon)          // the icon only depends on the app
        } else if let png = MacIcon.sourcePNG(in: iconSource ?? app.url, info: guestInfo) {
            try? MacIcon.makeICNS(from: png, to: stagedIcon, scratch: work)
        }
        if !fm.fileExists(atPath: stagedIcon.path) {
            // No usable icon in the app: use LiveContainer's own, so the Dock shows something.
            if let own = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { try? fm.copyItem(at: own, to: stagedIcon) }
        }
        try LCPlist.write(info, to: stagedContents.appendingPathComponent("Info.plist"))
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none",
                                             "--identifier", bundleIdentifier(for: app), staged.path])
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: launcher.path) {
            _ = try fm.replaceItemAt(launcher, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: launcher)
        }
        register(launcher)
    }

    func remove(for app: LCApp) {
        let launcher = url(for: app)
        _ = try? Shell.run(Launchers.lsregister, ["-u", launcher.path])
        if isInApplications(app) {
            try? FileManager.default.trashItem(at: launcher, resultingItemURL: nil)    // the user put it there
        } else {
            try? FileManager.default.removeItem(at: launcher)                          // regenerated on demand
        }
    }

    /// Moves the launcher to `folder` (~/Applications by default), named after the app, so it
    /// shows up in Launchpad and Spotlight and can be kept in the Dock.
    @discardableResult
    func addToApplications(_ app: LCApp, folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")) throws -> URL {
        try make(for: app)
        let current = url(for: app)
        let name = app.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("\(name).app")
        guard current.standardizedFileURL != destination.standardizedFileURL else { return destination }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LCError.message("\(destination.path) already exists")
        }
        _ = try? Shell.run(Launchers.lsregister, ["-u", current.path])
        try FileManager.default.moveItem(at: current, to: destination)
        var info = app.appInfo
        info["LCMacLauncherPath"] = destination.path
        app.appInfo = info
        register(destination)
        return destination
    }

    /// Moves the launcher back into LiveContainer's own folder.
    func removeFromApplications(_ app: LCApp) throws {
        guard isInApplications(app) else { return }
        let current = url(for: app)
        var info = app.appInfo
        info["LCMacLauncherPath"] = nil
        app.appInfo = info
        let destination = url(for: app)
        try FileManager.default.createDirectory(at: paths.launchers, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        _ = try? Shell.run(Launchers.lsregister, ["-u", current.path])
        if FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.moveItem(at: current, to: destination)
        }
        try make(for: app)
        register(destination)
    }

    struct LaunchOptions {
        var container: LCContainer?
        var url: String?
        var environment: [String: String] = [:]
        var waitUntilExit = false
    }

    /// Starts the app. If the container is already open, brings that window to the front.
    func launch(_ app: LCApp, _ options: LaunchOptions = LaunchOptions()) throws {
        try make(for: app)
        guard let container = options.container ?? app.defaultContainer else { throw LCError.noContainer }
        if container.isRunning, options.url == nil {
            activate(container)
            return
        }
        var arguments = ["-n"]
        if options.waitUntilExit { arguments.append("-W") }
        var environment = options.environment
        if container.folderName != app.defaultContainer?.folderName { environment["LC_SELECTED_CONTAINER"] = container.folderName }
        if !paths.isDefault { environment["LC_HOME_PATH"] = paths.home.path }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        arguments += ["-a", url(for: app).path]
        if let link = options.url { arguments.append(link) }
        try Shell.run("/usr/bin/open", arguments)
    }

    /// The process that has the container open, from the pid in its lock file.
    func process(for container: LCContainer) -> NSRunningApplication? {
        guard container.isRunning,
              let text = try? String(contentsOf: container.url.appendingPathComponent("LCContainer.lock"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    func activate(_ container: LCContainer) {
        process(for: container)?.activate()
    }

    func quit(_ container: LCContainer) {
        process(for: container)?.terminate()
    }

    // MARK: - Helpers

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private func register(_ launcher: URL) {
        _ = try? Shell.run(Launchers.lsregister, ["-f", launcher.path])
    }

    private func sanitizedName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "App" : clean
    }
}
