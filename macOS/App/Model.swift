import SwiftUI
import UniformTypeIdentifiers

// The app's state. The work is done by the shared code in macOS/Sources, which the lcmac
// command-line tool uses too, so the two always agree about what is installed.

@MainActor
final class LibraryModel: ObservableObject {
    @Published var apps: [LCApp] = []
    @Published var running: Set<String> = []          // container folder names
    @Published var tweaks: [TweakItem] = []
    @Published var activity: Activity?
    @Published var notice: String? { didSet { scheduleClear() } }
    @Published var failure: String?
    @Published var revision = 0                       // bumped when anything changes on disk

    struct Activity: Equatable {
        var title: String
        var detail: String
    }

    let library = LCLibrary()
    var launchers: Launchers { Launchers(paths: library.paths) }
    var isBusy: Bool { activity != nil }
    private var icons: [URL: NSImage] = [:]
    private var clearTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        try? library.paths.createFolders()
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // A launched app takes a moment to open its container.
                    self?.refreshRunning()
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.refreshRunning()
                }
            })
        }
        // Launchers name this copy of LiveContainer's runtime; refresh them if the app moved.
        let apps = self.apps, launchers = self.launchers
        Task.detached(priority: .utility) {
            for app in apps { try? launchers.make(for: app) }
            await MainActor.run { self.reload() }
        }
    }

    func reload() {
        apps = library.apps()
        icons.removeAll()
        tweaks = TweakItem.all(in: library.paths.tweaks)
        refreshRunning()
        revision += 1
    }

    func refreshRunning() {
        running = Set(apps.flatMap(\.containers).filter(\.isRunning).map(\.folderName))
    }

    func isRunning(_ app: LCApp) -> Bool { app.containers.contains { running.contains($0.folderName) } }
    var runningApps: [LCApp] { apps.filter(isRunning) }

    func icon(for app: LCApp) -> NSImage {
        if let cached = icons[app.url] { return cached }
        let image = app.icon.flatMap(NSImage.init(contentsOf:)) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[app.url] = image
        return image
    }

    // MARK: Apps

    func install(_ source: URL) {
        guard !isBusy else { return }
        activity = Activity(title: "Installing \(source.deletingPathExtension().lastPathComponent)", detail: "Starting…")
        let library = self.library
        let installedBefore = Set(apps.map(\.bundleIdentifier))
        Task.detached(priority: .userInitiated) {
            var installer = Installer(library: library)
            installer.log = { message in Task { @MainActor in self.activity?.detail = message } }
            do {
                let app = try installer.install(source)
                let isUpdate = installedBefore.contains(app.bundleIdentifier)
                await self.finish("\(isUpdate ? "Updated" : "Installed") \(app.displayName) \(app.version)")
                if !isUpdate { await self.run(app) }
            } catch {
                await self.finish(nil, failure: "\(source.lastPathComponent): \(error)")
            }
        }
    }

    func run(_ app: LCApp, container: LCContainer? = nil) {
        let launchers = self.launchers
        Task.detached(priority: .userInitiated) {
            do {
                try launchers.launch(app, .init(container: container))
            } catch {
                await MainActor.run { self.failure = "\(app.displayName): \(error)" }
            }
        }
    }

    func quit(_ container: LCContainer) { launchers.quit(container) }

    func uninstall(_ app: LCApp, deleteData: Bool) {
        perform(app) {
            try Installer(library: library).uninstall(app, deleteData: deleteData)
            notice = deleteData ? "Uninstalled \(app.displayName) and its data" : "Uninstalled \(app.displayName); its data is kept"
        }
    }

    func addContainer(to app: LCApp, name: String) {
        perform(app) { try library.addContainer(to: app, name: name) }
    }

    /// Runs slow file work (backups) off the main thread, with the progress card showing.
    func inBackground(_ title: String, _ work: @escaping @Sendable () throws -> String) {
        guard !isBusy else { return }
        activity = Activity(title: title, detail: "This can take a while for a large container…")
        Task.detached(priority: .userInitiated) {
            do {
                let message = try work()
                await self.finish(message)
            } catch {
                await self.finish(nil, failure: "\(error)")
            }
        }
    }

    func perform(_ app: LCApp?, _ body: () throws -> Void) {
        do { try body() } catch { failure = app.map { "\($0.displayName): \(error)" } ?? "\(error)" }
        reload()
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Install an iOS App"
        panel.message = "Choose a decrypted .ipa file."
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa"), .applicationBundle].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    // MARK: Tweaks

    func importTweak(_ source: URL, folder: String? = nil) {
        perform(nil) {
            let destination = try Installer(library: library).importTweak(source, folder: folder)
            notice = "Added \(destination.lastPathComponent)"
        }
    }

    func chooseTweak(folder: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Add a Tweak"
        panel.message = "A .dylib or .framework. It is converted for this Mac when added."
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib"), UTType(filenameExtension: "framework")].compactMap { $0 }
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { importTweak(url, folder: folder) } }
    }

    func setEnabled(_ tweak: TweakItem, _ enabled: Bool) {
        perform(nil) { try tweak.setEnabled(enabled) }
    }

    func remove(_ tweak: TweakItem) {
        perform(nil) { try library.paths.discard(tweak.url) }
    }

    func addTweakSet(_ name: String) {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        perform(nil) {
            try FileManager.default.createDirectory(at: library.paths.tweaks.appendingPathComponent(clean), withIntermediateDirectories: true)
        }
    }

    /// Tweak sets: the subfolders of Tweaks, any of which an app can load.
    var tweakSets: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: library.paths.tweaks, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "framework" }
            .map(\.lastPathComponent).sorted()
    }

    // MARK: Messages

    private func scheduleClear() {
        clearTask?.cancel()
        guard notice != nil else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private func finish(_ message: String?, failure: String? = nil) {
        activity = nil
        notice = message
        self.failure = failure
        reload()
    }
}

/// A tweak in the Tweaks folder: global when directly inside it, otherwise part of a set.
/// TweakLoader skips names ending in ".disabled", which is how a tweak is switched off.
struct TweakItem: Identifiable, Hashable {
    let url: URL
    let set: String?
    var id: URL { url }
    var isEnabled: Bool { url.pathExtension != "disabled" }
    var name: String { isEnabled ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
    var kind: String { (name as NSString).pathExtension == "framework" ? "Framework" : "Library" }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        let target = enabled ? url.deletingPathExtension() : url.appendingPathExtension("disabled")
        try FileManager.default.moveItem(at: url, to: target)
    }

    static func all(in root: URL) -> [TweakItem] {
        func isTweak(_ url: URL) -> Bool {
            let name = url.pathExtension == "disabled" ? url.deletingPathExtension() : url
            return ["dylib", "framework"].contains(name.pathExtension) && url.lastPathComponent != "TweakLoader.dylib"
        }
        let fm = FileManager.default
        var result: [TweakItem] = []
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if isTweak(item) {
                result.append(TweakItem(url: item, set: nil))
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let walker = fm.enumerator(at: item, includingPropertiesForKeys: nil)
                while let child = walker?.nextObject() as? URL {
                    if isTweak(child) {
                        result.append(TweakItem(url: child, set: item.lastPathComponent))
                        walker?.skipDescendants()
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
