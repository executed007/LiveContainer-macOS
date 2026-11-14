import Foundation

// lcmac: LiveContainer for macOS from the command line. Everything the app does, scriptable.

let usage = """
usage: lcmac <command> [arguments]

Apps
  install <file.ipa|App.app> [--run] [--keep-ios]   install or update an app
  list                                              installed apps and their containers
  run <app> [--container <name>] [--url <link>] [--env KEY=VALUE] [--wait]
  uninstall <app> [--delete-data]                   move to the Trash (data kept unless asked)
  info <app>                                        details, settings and paths

Containers (separate data, accounts and keychain per container)
  containers <app>                                  list
  container add <app> <name>
  container rename <app> <container> <new name>
  container default <app> <container>               the one opened by default
  container reset <app> <container>                 erase its data, keep it
  container remove <app> <container> [--keep-data]
  path <app> [--container <name>]                   print the container's folder

Settings
  set <app> <option> <value> [--container <name>]   LiveContainer options (see `lcmac options`)
  mac <app> <setting> <value>                       Mac adaptations (see `lcmac options`)
  options                                           list both kinds with their values

Tweaks
  tweak add <file.dylib|Tweak.framework> [--folder <name>]
  tweaks                                            list the Tweaks folder

Mac integration
  export <app> [--to <folder>]                      put the app in ~/Applications (Launchpad, Spotlight)
  unexport <app>                                    take it out again
  inspect <binary>                                  platform, minimum OS, encryption, file type

Environment: LC_HOME_PATH changes where LiveContainer keeps everything
(default ~/Library/Application Support/LiveContainer).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let library = LCLibrary()
let launchers = Launchers(paths: library.paths)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lcmac: \(message)\n".utf8))
    exit(1)
}

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func positional(_ index: Int, _ what: String) -> String {
    guard index < arguments.count else { fail("missing \(what)\n\n\(usage)") }
    return arguments[index]
}

func findApp(_ query: String) -> LCApp {
    guard let app = library.app(query) else { fail("no installed app matches \"\(query)\" (see `lcmac list`)") }
    return app
}

func findContainer(_ app: LCApp, _ query: String?) -> LCContainer {
    guard let query else {
        guard let container = app.defaultContainer else { fail(LCError.noContainer.description) }
        return container
    }
    guard let container = app.container(named: query) else { fail("\(app.displayName) has no container \"\(query)\"") }
    return container
}

func sizeString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

func run(_ body: () throws -> Void) {
    do { try body() } catch { fail("\(error)") }
}

guard let command = arguments.first else { print(usage); exit(0) }
arguments.removeFirst()

switch command {
case "install":
    var installer = Installer(library: library)
    installer.options.keepIOSPlatform = flag("--keep-ios")
    let runAfter = flag("--run")
    let source = URL(fileURLWithPath: positional(0, "an .ipa or .app")).standardizedFileURL
    run {
        let start = Date()
        let app = try installer.install(source)
        print("Installed \(app.displayName) \(app.version) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        if runAfter { try launchers.launch(app) }
    }

case "list":
    let apps = library.apps()
    if apps.isEmpty { print("No apps installed. Install one with: lcmac install App.ipa") }
    for app in apps {
        print("\(app.displayName) \(app.version)  [\(app.bundleIdentifier)]")
        let defaultID = app.defaultContainer?.folderName
        for container in app.containers {
            var marks: [String] = []
            if container.folderName == defaultID { marks.append("default") }
            if container.isRunning { marks.append("running") }
            print("    \(container.name)\(marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))")  \(container.folderName)")
        }
    }

case "run":
    let containerName = option("--container")
    let link = option("--url")
    let wait = flag("--wait")
    var environment: [String: String] = [:]
    while let pair = option("--env") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--env takes KEY=VALUE") }
        environment[parts[0]] = parts[1]
    }
    let app = findApp(positional(0, "an app"))
    let container = findContainer(app, containerName)
    run { try launchers.launch(app, .init(container: container, url: link, environment: environment, waitUntilExit: wait)) }

case "uninstall":
    let deleteData = flag("--delete-data")
    let app = findApp(positional(0, "an app"))
    run {
        try Installer(library: library).uninstall(app, deleteData: deleteData)
        print("Moved \(app.displayName) to the Trash\(deleteData ? " with its data" : "; its data is kept")")
    }

case "info":
    let app = findApp(positional(0, "an app"))
    let info = app.appInfo
    print("""
    \(app.displayName) \(app.version)
      bundle identifier  \(app.bundleIdentifier)
      installed in       \(app.url.path)
      launcher           \(launchers.url(for: app).path)\(launchers.isInApplications(app) ? " (in Applications)" : "")
      Mac Catalyst       \((info["LCMacConverted"] as? Bool ?? false) ? "converted at install" : "kept as iOS (needs dyld patch)")
      tweaks             \((info["dontInjectTweakLoader"] as? Bool ?? false) ? "off" : "on")\((info["LCTweakFolder"] as? String).map { ", set \"\($0)\"" } ?? "")
    """)
    for option in LCOption.allCases where !option.isContainerOption {
        if let value = info[option.rawValue] { print("  \(option.rawValue) = \(value)") }
    }
    print("  containers:")
    for container in app.containers {
        print("    \(container.name)  \(sizeString(LCLibrary.size(of: container.url)))  \(container.url.path)")
    }

case "containers":
    let app = findApp(positional(0, "an app"))
    for container in app.containers {
        let isDefault = container.folderName == app.defaultContainer?.folderName
        print("\(container.name)\(isDefault ? " (default)" : "")\(container.isRunning ? " (running)" : "")  \(container.folderName)  \(sizeString(LCLibrary.size(of: container.url)))")
    }

case "container":
    let action = positional(0, "add, rename, default, reset or remove")
    let app = findApp(positional(1, "an app"))
    run {
        switch action {
        case "add":
            let container = try library.addContainer(to: app, name: positional(2, "a name"))
            print("Added container \(container.name) (\(container.folderName))")
        case "rename":
            library.renameContainer(findContainer(app, positional(2, "a container")), of: app, to: positional(3, "a new name"))
        case "default":
            library.setDefaultContainer(findContainer(app, positional(2, "a container")), of: app)
        case "reset":
            try library.resetContainer(findContainer(app, positional(2, "a container")))
        case "remove":
            let keep = flag("--keep-data")
            try library.removeContainer(findContainer(app, positional(2, "a container")), from: app, keepData: keep)
        default:
            fail("unknown container action \(action)")
        }
    }

case "path":
    let containerName = option("--container")
    print(findContainer(findApp(positional(0, "an app")), containerName).url.path)

case "set":
    let containerName = option("--container")
    let app = findApp(positional(0, "an app"))
    let key = positional(1, "an option")
    guard let lcOption = LCOption.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(key) == .orderedSame || "\($0)".caseInsensitiveCompare(key) == .orderedSame }) else {
        fail("unknown option \(key) (see `lcmac options`)")
    }
    run { try library.setOption(lcOption, positional(2, "a value"), app: app, container: containerName.map { findContainer(app, $0) }) }

case "mac":
    let app = findApp(positional(0, "an app"))
    let key = positional(1, "a setting"), value = positional(2, "a value")
    var settings = app.settings
    let on = ["on", "yes", "true", "1"].contains(value.lowercased())
    switch key {
    case "hideTitleBar": settings.hideTitleBar = on
    case "lockCameraOrientation": settings.lockCameraOrientation = on
    case "cropCameraToPortrait": settings.cropCameraToPortrait = on
    case "arrowKeysScrollFeed": settings.arrowKeysScrollFeed = on
    case "showVolumeButton": settings.showVolumeButton = on
    case "windowSize":
        guard ["default", "phone", "tablet"].contains(value) else { fail("windowSize is default, phone or tablet") }
        settings.windowSize = value
    case "volume":
        guard let level = Double(value.replacingOccurrences(of: "%", with: "")) else { fail("volume is 0-100") }
        settings.volume = min(max(level > 1 ? level / 100 : level, 0), 1)
    default: fail("unknown Mac setting \(key) (see `lcmac options`)")
    }
    app.settings = settings

case "options":
    print("LiveContainer options (lcmac set <app> <option> <value>):")
    for option in LCOption.allCases { print("  \(option.rawValue)\n      \(option.help)") }
    print("""

    Mac adaptations (lcmac mac <app> <setting> <value>):
      hideTitleBar on/off            full-height layout, window buttons in the corner (default on)
      windowSize default/phone/tablet  window size at launch
      volume 0-100                   level for everything the app plays (default 100)
      showVolumeButton on/off        speaker button and slider in the window (default on)
      arrowKeysScrollFeed on/off     ↑ and ↓ page a full-screen feed (default on)
      lockCameraOrientation on/off   keep the camera image upright (default on)
      cropCameraToPortrait on/off    give the app a 9:16 portrait camera image (default on)
    """)

case "tweak":
    guard positional(0, "add") == "add" else { fail("usage: lcmac tweak add <file> [--folder <name>]") }
    let folder = option("--folder")
    let source = URL(fileURLWithPath: positional(1, "a .dylib or .framework")).standardizedFileURL
    run {
        let destination = try Installer(library: library).importTweak(source, folder: folder)
        print("Added \(destination.lastPathComponent) to \(destination.deletingLastPathComponent().path)")
    }

case "tweaks":
    let walker = FileManager.default.enumerator(atPath: library.paths.tweaks.path)
    var any = false
    while let item = walker?.nextObject() as? String {
        guard item.hasSuffix(".dylib") || item.hasSuffix(".framework"), item != "TweakLoader.dylib" else { continue }
        print(item); any = true
    }
    if !any { print("No tweaks. Add one with: lcmac tweak add Tweak.dylib") }

case "export":
    let folder = option("--to").map { URL(fileURLWithPath: $0) }
    let app = findApp(positional(0, "an app"))
    run {
        let destination = try folder.map { try launchers.addToApplications(app, folder: $0) } ?? launchers.addToApplications(app)
        print("Added \(destination.path)")
    }

case "unexport":
    run { try launchers.removeFromApplications(findApp(positional(0, "an app"))) }

case "inspect":
    let path = positional(0, "a binary")
    run {
        let thin = try MachO.thinned(try Data(contentsOf: URL(fileURLWithPath: path)))
        let platforms: [UInt32: String] = [1: "macOS", 2: "iOS", 6: "Mac Catalyst", 7: "iOS Simulator"]
        if let version = try MachO.buildVersion(thin) {
            func format(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xff)" }
            print("platform \(platforms[version.platform] ?? "\(version.platform)"), minimum OS \(format(version.minOS)), SDK \(format(version.sdk))")
        } else {
            print("platform unknown (no LC_BUILD_VERSION)")
        }
        print("file type \(MachO.isExecutable(thin) ? "executable" : thin.u32(12) == MachO.mhDylib ? "dylib" : "\(thin.u32(12))")")
        print(try MachO.isEncrypted(thin) ? "encrypted (FairPlay)" : "not encrypted")
    }

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
