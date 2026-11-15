import Foundation

/// Where LiveContainer keeps everything. The layout under Documents is upstream's, so the
/// runtime code shared with iOS finds apps, data and tweaks where it expects them:
///
///   ~/Library/Application Support/LiveContainer/
///     Documents/Applications/<bundle id>.app   installed apps (+ LCAppInfo.plist, LCMacSettings.plist)
///     Documents/Data/Application/<UUID>/       data containers (each one a separate home folder)
///     Documents/Tweaks/                        global tweaks; subfolders are per-app tweak sets
///     Launchers/<bundle id>.app                small Mac apps that start each installed app
struct LCPaths {
    var home: URL

    static let defaultHome = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveContainer")

    init(home: URL = ProcessInfo.processInfo.environment["LC_HOME_PATH"].map { URL(fileURLWithPath: $0) } ?? LCPaths.defaultHome) {
        self.home = home
    }

    var documents: URL { home.appendingPathComponent("Documents") }
    var applications: URL { documents.appendingPathComponent("Applications") }
    var data: URL { documents.appendingPathComponent("Data/Application") }
    var tweaks: URL { documents.appendingPathComponent("Tweaks") }
    var launchers: URL { home.appendingPathComponent("Launchers") }
    var isDefault: Bool { home.standardizedFileURL == LCPaths.defaultHome.standardizedFileURL }

    /// Removes something LiveContainer owns. In the real library it goes to the Trash so it
    /// can be recovered; under a custom LC_HOME_PATH (tests, development) it is deleted.
    func discard(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if isDefault {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    func createFolders() throws {
        for folder in [applications, data, tweaks, launchers] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// A data container: one home folder for an app. An app can have several (separate accounts,
/// or a clean profile for testing); each can run at the same time as the others.
struct LCContainer: Hashable, Identifiable {
    var folderName: String          // UUID, the folder under Data/Application
    var name: String
    var url: URL
    var id: String { folderName }

    /// Settings stored inside the container (upstream's LCContainerInfo.plist).
    var info: [String: Any] {
        get { LCPlist.read(url.appendingPathComponent("LCContainerInfo.plist")) }
        nonmutating set { try? LCPlist.write(newValue, to: url.appendingPathComponent("LCContainerInfo.plist")) }
    }

    /// True while a process has the container open (it holds an flock on LCContainer.lock).
    var isRunning: Bool {
        let fd = open(url.appendingPathComponent("LCContainer.lock").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    func hash(into hasher: inout Hasher) { hasher.combine(folderName) }
    static func == (a: LCContainer, b: LCContainer) -> Bool { a.folderName == b.folderName && a.name == b.name }
}

/// An installed app: its bundle in Documents/Applications plus LiveContainer's records.
struct LCApp: Identifiable, Hashable {
    let url: URL
    let paths: LCPaths
    var id: String { folderName }
    var folderName: String { url.lastPathComponent }

    var info: [String: Any] { LCPlist.read(url.appendingPathComponent("Info.plist")) }

    /// Upstream's per-app record (LCAppInfo.plist).
    var appInfo: [String: Any] {
        get { LCPlist.read(url.appendingPathComponent("LCAppInfo.plist")) }
        nonmutating set { try? LCPlist.write(newValue, to: url.appendingPathComponent("LCAppInfo.plist")) }
    }

    var bundleIdentifier: String { info["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent }
    var displayName: String {
        let info = self.info
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleIdentifier
    }
    var version: String {
        let info = self.info
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
    var shortVersion: String { info["CFBundleShortVersionString"] as? String ?? version }
    var icon: URL? {
        let icns = paths.launchers.appendingPathComponent(folderName).appendingPathComponent("Contents/Resources/AppIcon.icns")
        return FileManager.default.fileExists(atPath: icns.path) ? icns : nil
    }

    var settings: LCMacSettings {
        get { LCMacSettings.load(from: url.appendingPathComponent("LCMacSettings.plist")) }
        nonmutating set { try? newValue.save(to: url.appendingPathComponent("LCMacSettings.plist")) }
    }

    var containers: [LCContainer] {
        let list = appInfo["LCContainers"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let folder = entry["folderName"] as? String else { return nil }
            return LCContainer(folderName: folder, name: entry["name"] as? String ?? folder,
                               url: paths.data.appendingPathComponent(folder))
        }
    }

    var defaultContainer: LCContainer? {
        let uuid = appInfo["LCDataUUID"] as? String
        return containers.first { $0.folderName == uuid } ?? containers.first
    }

    func container(named nameOrUUID: String) -> LCContainer? {
        containers.first { $0.folderName.caseInsensitiveCompare(nameOrUUID) == .orderedSame }
            ?? containers.first { $0.name.caseInsensitiveCompare(nameOrUUID) == .orderedSame }
    }

    var isRunning: Bool { containers.contains { $0.isRunning } }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (a: LCApp, b: LCApp) -> Bool { a.url == b.url }
}

/// Per-app Mac adaptations, read by macOS/Runtime/LCMacSupport.m from LCMacSettings.plist.
struct LCMacSettings: Codable, Equatable {
    var hideTitleBar = true
    var lockCameraOrientation = true
    var cropCameraToPortrait = true
    var windowSize = "default"          // "default", "phone" or "tablet"
    var arrowKeysScrollFeed = true
    var volume = 1.0                    // 0...1, scales what the app plays
    var showVolumeButton = true

    static let changedNotification = "com.kdt.livecontainer.mac.settings-changed"

    static func load(from url: URL) -> LCMacSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? PropertyListDecoder().decode(LCMacSettings.self, from: data) else { return LCMacSettings() }
        return settings
    }

    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: url)
        // Running apps pick up the change (the volume applies straight away).
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(LCMacSettings.changedNotification as CFString), nil, nil, true)
    }

    // Keys added later must not make older files unreadable.
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hideTitleBar = try values.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? true
        lockCameraOrientation = try values.decodeIfPresent(Bool.self, forKey: .lockCameraOrientation) ?? true
        cropCameraToPortrait = try values.decodeIfPresent(Bool.self, forKey: .cropCameraToPortrait) ?? true
        windowSize = try values.decodeIfPresent(String.self, forKey: .windowSize) ?? "default"
        arrowKeysScrollFeed = try values.decodeIfPresent(Bool.self, forKey: .arrowKeysScrollFeed) ?? true
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        showVolumeButton = try values.decodeIfPresent(Bool.self, forKey: .showVolumeButton) ?? true
    }
}

/// LiveContainer options from upstream that apply on a Mac, stored in LCAppInfo.plist (app)
/// or LCContainerInfo.plist (container) under upstream's key names.
enum LCOption: String, CaseIterable {
    case hideLiveContainer          // hide LiveContainer's images from the app (dyld image list)
    case spoofSDKVersion            // report this iOS SDK version to the app, e.g. "16.0"
    case language = "LCSelectedLanguage"
    case tweakFolder = "LCTweakFolder"
    case dontInjectTweakLoader      // load no tweaks at all
    case doSymlinkInbox             // keep the app's Inbox folder for files opened in it
    case spoofIdentifierForVendor   // container: a fixed identifierForVendor per container

    var help: String {
        switch self {
        case .hideLiveContainer: "on/off: hide LiveContainer from the app's list of loaded images"
        case .spoofSDKVersion: "version (e.g. 16.0) or off: the iOS SDK version the app is told it was built with"
        case .language: "language code (e.g. fr) or off: run the app in this language"
        case .tweakFolder: "folder name under Tweaks, or off: per-app tweak set to load"
        case .dontInjectTweakLoader: "on/off: load no tweaks for this app"
        case .doSymlinkInbox: "on/off: keep files opened in the app in its Inbox folder"
        case .spoofIdentifierForVendor: "on/off (per container): a fixed identifierForVendor for this container"
        }
    }
    var isContainerOption: Bool { self == .spoofIdentifierForVendor }
}

enum LCPlist {
    static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    static func write(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
    }
}

/// Lists and edits what is installed. Thin layer over the folders; nothing is cached, so the
/// command-line tool and the app always agree.
struct LCLibrary {
    var paths = LCPaths()

    func apps() -> [LCApp] {
        let items = (try? FileManager.default.contentsOfDirectory(at: paths.applications, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("LCAppInfo.plist").path) }
            .map { LCApp(url: $0, paths: paths) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Finds an app by folder name, bundle identifier, display name, bundle name or executable.
    func app(_ query: String) -> LCApp? {
        let all = apps()
        func same(_ value: Any?) -> Bool { (value as? String)?.caseInsensitiveCompare(query) == .orderedSame }
        return all.first { $0.folderName == query || $0.folderName == query + ".app" }
            ?? all.first { same($0.bundleIdentifier) }
            ?? all.first { same($0.displayName) }
            ?? all.first { same($0.info["CFBundleName"]) || same($0.info["CFBundleExecutable"]) }
    }

    @discardableResult
    func addContainer(to app: LCApp, name: String) throws -> LCContainer {
        let folder = UUID().uuidString
        let url = paths.data.appendingPathComponent(folder)
        try LCLibrary.makeContainerFolders(url)
        var info = app.appInfo
        var list = info["LCContainers"] as? [[String: Any]] ?? []
        list.append(["folderName": folder, "name": name])
        info["LCContainers"] = list
        if info["LCDataUUID"] == nil { info["LCDataUUID"] = folder }
        app.appInfo = info
        let container = LCContainer(folderName: folder, name: name, url: url)
        container.info = ["name": name, "appIdentifier": app.bundleIdentifier]
        return container
    }

    func renameContainer(_ container: LCContainer, of app: LCApp, to name: String) {
        var info = app.appInfo
        info["LCContainers"] = (info["LCContainers"] as? [[String: Any]] ?? []).map { entry in
            var entry = entry
            if entry["folderName"] as? String == container.folderName { entry["name"] = name }
            return entry
        }
        app.appInfo = info
        var containerInfo = container.info
        containerInfo["name"] = name
        container.info = containerInfo
    }

    func setDefaultContainer(_ container: LCContainer, of app: LCApp) {
        var info = app.appInfo
        info["LCDataUUID"] = container.folderName
        app.appInfo = info
    }

    /// Removes a container from the app. Its folder is moved to the Trash unless `keepData`.
    func removeContainer(_ container: LCContainer, from app: LCApp, keepData: Bool = false) throws {
        guard !container.isRunning else { throw LCError.running(app.displayName) }
        var info = app.appInfo
        var list = info["LCContainers"] as? [[String: Any]] ?? []
        list.removeAll { $0["folderName"] as? String == container.folderName }
        guard !list.isEmpty else { throw LCError.lastContainer }
        info["LCContainers"] = list
        if info["LCDataUUID"] as? String == container.folderName { info["LCDataUUID"] = list[0]["folderName"] }
        app.appInfo = info
        if !keepData { try paths.discard(container.url) }
    }

    /// Empties a container (back to a fresh install's state) without removing it.
    func resetContainer(_ container: LCContainer) throws {
        guard !container.isRunning else { throw LCError.running(container.name) }
        let info = container.info
        for item in (try? FileManager.default.contentsOfDirectory(at: container.url, includingPropertiesForKeys: nil)) ?? [] {
            try FileManager.default.removeItem(at: item)
        }
        try LCLibrary.makeContainerFolders(container.url)
        container.info = info
    }

    /// Deletes what the app keeps only as a cache (Library/Caches and tmp); logins and files stay.
    func clearCaches(_ container: LCContainer) throws {
        guard !container.isRunning else { throw LCError.running(container.name) }
        for folder in ["Library/Caches", "tmp"] {
            let url = container.url.appendingPathComponent(folder)
            for item in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    static let backupManifest = "LiveContainerBackup.plist"

    /// Saves a container to a zip file: its data (keychain included) and a manifest naming the app.
    func backup(_ container: LCContainer, of app: LCApp, to file: URL) throws {
        // An open container has databases mid-write; a copy of them can be unusable.
        guard !container.isRunning else { throw LCError.running(app.displayName) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("lc-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try LCPlist.write(["bundleIdentifier": app.bundleIdentifier, "appName": app.displayName, "appVersion": app.version,
                           "containerName": container.name, "date": Date()],
                          to: staging.appendingPathComponent(LCLibrary.backupManifest))
        try Shell.run("/bin/cp", ["-cR", container.url.path, staging.appendingPathComponent("Data").path])
        try? FileManager.default.removeItem(at: staging.appendingPathComponent("Data/LCContainer.lock"))
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, file.path])
    }

    /// Restores a backup as a new container of the app; existing containers are never touched.
    @discardableResult
    func restore(_ file: URL, into app: LCApp) throws -> LCContainer {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("lc-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path])
        let manifest = LCPlist.read(staging.appendingPathComponent(LCLibrary.backupManifest))
        let data = staging.appendingPathComponent("Data")
        guard let identifier = manifest["bundleIdentifier"] as? String,
              FileManager.default.fileExists(atPath: data.path) else {
            throw LCError.message("\(file.lastPathComponent) is not a LiveContainer backup")
        }
        guard identifier == app.bundleIdentifier else {
            throw LCError.message("This backup is of \(manifest["appName"] as? String ?? identifier), not \(app.displayName)")
        }
        let name = "\(manifest["containerName"] as? String ?? "Backup") (restored)"
        let container = try addContainer(to: app, name: name)
        try FileManager.default.removeItem(at: container.url)
        try FileManager.default.moveItem(at: data, to: container.url)
        try LCLibrary.makeContainerFolders(container.url)
        var info = container.info
        info["name"] = name
        container.info = info
        return container
    }

    static func makeContainerFolders(_ url: URL) throws {
        // iOS LiveContainer makes tmp a symlink; a Mac container needs a real folder.
        let tmp = url.appendingPathComponent("tmp")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: tmp.path)) != nil {
            try FileManager.default.removeItem(at: tmp)
        }
        for folder in ["Documents", "Library/Caches", "Library/Preferences", "Library/Application Support", "tmp", "SystemData"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    /// Bytes used by a folder, counting each file's allocated size.
    static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func setOption(_ option: LCOption, _ value: String, app: LCApp, container: LCContainer? = nil) throws {
        let off = ["off", "no", "false", "0", "none", ""].contains(value.lowercased())
        let on = ["on", "yes", "true", "1"].contains(value.lowercased())
        if option.isContainerOption {
            guard let container = container ?? app.defaultContainer else { throw LCError.noContainer }
            var info = container.info
            info[option.rawValue] = on
            if on, info["spoofedIdentifierForVendor"] == nil { info["spoofedIdentifierForVendor"] = UUID().uuidString }
            container.info = info
            return
        }
        var info = app.appInfo
        switch option {
        case .hideLiveContainer, .dontInjectTweakLoader, .doSymlinkInbox:
            guard on || off else { throw LCError.badValue(option.rawValue, value) }
            info[option.rawValue] = on
        case .spoofSDKVersion:
            if off { info[option.rawValue] = nil } else {
                let parts = value.split(separator: ".").compactMap { UInt32($0) }
                guard (1...3).contains(parts.count) else { throw LCError.badValue(option.rawValue, value) }
                let padded = parts + Array(repeating: 0, count: 3 - parts.count)
                info[option.rawValue] = padded[0] << 16 | padded[1] << 8 | padded[2]
            }
        case .language, .tweakFolder:
            info[option.rawValue] = off ? nil : value
        case .spoofIdentifierForVendor:
            break
        }
        app.appInfo = info
    }
}

enum LCError: Error, CustomStringConvertible {
    case notInstalled(String), running(String), lastContainer, noContainer, badValue(String, String), message(String)

    var description: String {
        switch self {
        case .notInstalled(let name): "\(name) is not installed"
        case .running(let name): "\(name) is running; quit it first"
        case .lastContainer: "an app needs at least one container"
        case .noContainer: "the app has no container"
        case .badValue(let key, let value): "\(value) is not a valid value for \(key)"
        case .message(let text): text
        }
    }
}
