import SwiftUI
import UniformTypeIdentifiers

// LiveContainer for macOS: the app. A library of installed iOS apps, each with its data
// containers and settings. The work is done by the shared code in macOS/Sources, which the
// lcmac command-line tool uses too.

@MainActor
final class LibraryModel: ObservableObject {
    @Published var apps: [LCApp] = []
    @Published var running: Set<String> = []          // container folder names
    @Published var status = "" { didSet { scheduleClear() } }
    @Published var isBusy = false
    @Published var failure: String?
    @Published var revision = 0                       // bumped when settings change on disk

    let library = LCLibrary()
    var launchers: Launchers { Launchers(paths: library.paths) }
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
        refreshRunning()
        revision += 1
    }

    func refreshRunning() {
        running = Set(apps.flatMap(\.containers).filter(\.isRunning).map(\.folderName))
    }

    func icon(for app: LCApp) -> NSImage {
        if let cached = icons[app.url] { return cached }
        let image = app.icon.flatMap(NSImage.init(contentsOf:)) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[app.url] = image
        return image
    }

    // MARK: Actions

    func install(_ source: URL) {
        guard !isBusy else { return }
        isBusy = true
        status = "Installing \(source.lastPathComponent)..."
        let library = self.library
        Task.detached(priority: .userInitiated) {
            var installer = Installer(library: library)
            installer.log = { message in Task { @MainActor in self.status = message } }
            do {
                let isUpdate = installer.library.apps().contains { $0.url.lastPathComponent == source.lastPathComponent }
                let app = try installer.install(source)
                await self.finish("Installed \(app.displayName) \(app.version)", failure: nil)
                if !isUpdate { await self.run(app) }
            } catch {
                await self.finish("", failure: "\(source.lastPathComponent): \(error)")
            }
        }
    }

    func importTweak(_ source: URL, folder: String? = nil) {
        do {
            let destination = try Installer(library: library).importTweak(source, folder: folder)
            status = "Added tweak \(destination.lastPathComponent)"
        } catch {
            failure = "\(source.lastPathComponent): \(error)"
        }
    }

    func run(_ app: LCApp, container: LCContainer? = nil) {
        let launchers = self.launchers
        Task.detached(priority: .userInitiated) {
            do {
                try launchers.launch(app, .init(container: container))
                await MainActor.run { self.status = "Opened \(app.displayName)" }
            } catch {
                await MainActor.run { self.failure = "\(app.displayName): \(error)" }
            }
        }
    }

    func quit(_ container: LCContainer) { launchers.quit(container) }

    func uninstall(_ app: LCApp, deleteData: Bool) {
        perform(app) {
            try Installer(library: library).uninstall(app, deleteData: deleteData)
            status = deleteData ? "Uninstalled \(app.displayName) and deleted its data" : "Uninstalled \(app.displayName); its data is kept"
        }
    }

    func addContainer(to app: LCApp, name: String) {
        perform(app) { try library.addContainer(to: app, name: name) }
    }

    func perform(_ app: LCApp, _ body: () throws -> Void) {
        do { try body() } catch { failure = "\(app.displayName): \(error)" }
        reload()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an iOS app"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa"), .applicationBundle].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    func chooseTweak() {
        let panel = NSOpenPanel()
        panel.title = "Choose a tweak"
        panel.message = "A .dylib or .framework. It is converted for this Mac and loaded into every app."
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib"), UTType(filenameExtension: "framework")].compactMap { $0 }
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { importTweak(url) }
    }

    /// Tweak sets: the subfolders of Tweaks, any of which an app can load.
    var tweakFolders: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: library.paths.tweaks, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "framework" }
            .map(\.lastPathComponent).sorted()
    }

    private func scheduleClear() {
        clearTask?.cancel()
        guard !status.isEmpty else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            self.status = ""
        }
    }

    private func finish(_ message: String, failure: String?) {
        isBusy = false
        status = message
        self.failure = failure
        reload()
    }
}

// MARK: - Library grid

struct AppIconView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

struct AppCard: View {
    let app: LCApp
    let icon: NSImage
    let runningCount: Int
    let run: () -> Void
    let configure: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            AppIconView(image: icon, size: 84)
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 8 : 4, y: hovering ? 5 : 2)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .padding(11).background(.black.opacity(0.5), in: Circle())
                        .opacity(hovering ? 1 : 0)
                }
                .scaleEffect(hovering ? 1.04 : 1)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    if runningCount > 0 { Circle().fill(.green).frame(width: 6, height: 6).help("Running") }
                    Text(app.displayName).font(.callout.weight(.medium)).lineLimit(1)
                }
                let containers = app.containers.count
                Text(containers > 1 ? "\(app.version) · \(containers) containers" : app.version)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16).padding(.bottom, 12).padding(.horizontal, 8)
        .background(.background.opacity(hovering ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.14 : 0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: run)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, run)
        .overlay(alignment: .topTrailing) {
            Button(action: configure) {
                Image(systemName: "slider.horizontal.3").font(.caption).padding(6).background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings for \(app.displayName)")
            .accessibilityLabel("Settings for \(app.displayName)")
            .padding(7)
            .opacity(hovering ? 1 : 0.45)
        }
    }
}

// MARK: - App settings

struct ContainerRow: View {
    let app: LCApp
    let container: LCContainer
    @ObservedObject var model: LibraryModel
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingReset = false
    @State private var confirmingRemove = false
    @State private var size: String = "…"

    var isDefault: Bool { container.folderName == app.defaultContainer?.folderName }
    var isRunning: Bool { model.running.contains(container.folderName) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isRunning ? "circle.fill" : "circle").font(.system(size: 7))
                .foregroundStyle(isRunning ? .green : .secondary.opacity(0.4))
                .help(isRunning ? "Running" : "Not running")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(container.name).fontWeight(.medium)
                    if isDefault { Text("Default").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning {
                Button("Show") { model.launchers.activate(container) }
                Button("Quit") { model.quit(container) }
            } else {
                Button("Open") { model.run(app, container: container) }
            }
            Menu {
                if !isDefault { Button("Open by Default") { model.perform(app) { model.library.setDefaultContainer(container, of: app) } } }
                Button("Rename…") { newName = container.name; renaming = true }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([container.url.appendingPathComponent("Documents")]) }
                Toggle("Own Identifier for Vendor", isOn: Binding(
                    get: { container.info["spoofIdentifierForVendor"] as? Bool ?? false },
                    set: { value in model.perform(app) { try model.library.setOption(.spoofIdentifierForVendor, value ? "on" : "off", app: app, container: container) } }))
                Divider()
                Button("Erase Data…") { confirmingReset = true }.disabled(isRunning)
                Button("Remove Container…", role: .destructive) { confirmingRemove = true }.disabled(isRunning || app.containers.count < 2)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .task(id: model.revision) {
            let url = container.url
            let bytes = await Task.detached { LCLibrary.size(of: url) }.value
            size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        .alert("Rename Container", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.perform(app) { model.library.renameContainer(container, of: app, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Erase everything in \(container.name)?", isPresented: $confirmingReset) {
            Button("Erase Data", role: .destructive) { model.perform(app) { try model.library.resetContainer(container) } }
        } message: { Text("Logins, downloads and settings saved by the app in this container are deleted. The container stays, empty.") }
        .confirmationDialog("Remove \(container.name)?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive) { model.perform(app) { try model.library.removeContainer(container, from: app) } }
        } message: { Text("The container and everything the app saved in it go to the Trash.") }
    }
}

struct AppSettingsSheet: View {
    let app: LCApp
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: LCMacSettings
    @State private var appInfo: [String: Any]
    @State private var addingContainer = false
    @State private var containerName = ""
    @State private var sdkVersion: String
    @State private var language: String
    @State private var confirmingDelete = false

    init(app: LCApp, model: LibraryModel) {
        self.app = app
        self.model = model
        _settings = State(initialValue: app.settings)
        let info = app.appInfo
        _appInfo = State(initialValue: info)
        if let encoded = info["spoofSDKVersion"] as? Int, encoded > 0 {
            _sdkVersion = State(initialValue: "\(encoded >> 16).\((encoded >> 8) & 0xff)")
        } else {
            _sdkVersion = State(initialValue: "")
        }
        _language = State(initialValue: info["LCSelectedLanguage"] as? String ?? "")
    }

    private func flag(_ option: LCOption) -> Binding<Bool> {
        Binding(get: { appInfo[option.rawValue] as? Bool ?? false },
                set: { value in setOption(option, value ? "on" : "off") })
    }

    private func setOption(_ option: LCOption, _ value: String) {
        do {
            try model.library.setOption(option, value, app: app)
            appInfo = app.appInfo
        } catch {
            model.failure = "\(app.displayName): \(error)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(image: model.icon(for: app), size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName).font(.title3.weight(.semibold))
                    Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Version \(app.version)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Open") { model.run(app); dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(20)

            Form {
                Section {
                    ForEach(app.containers) { container in ContainerRow(app: app, container: container, model: model) }
                    Button("Add Container…", systemImage: "plus") { containerName = ""; addingContainer = true }
                } header: {
                    Text("Containers")
                } footer: {
                    Text("Each container is a separate copy of the app's data, with its own logins and keychain. Containers can be open at the same time, each in its own window.")
                }
                Section("Window") {
                    Toggle("Hide the title bar", isOn: $settings.hideTitleBar)
                    Picker("Size at launch", selection: $settings.windowSize) {
                        Text("Let the app decide").tag("default")
                        Text("Phone (430 × 932)").tag("phone")
                        Text("Tablet (1024 × 768)").tag("tablet")
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.volume, in: 0...1, step: 0.05)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        Text("\(Int((settings.volume * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Toggle("Show a volume button in the app", isOn: $settings.showVolumeButton)
                    Toggle("Arrow keys move through feeds", isOn: $settings.arrowKeysScrollFeed)
                } header: {
                    Text("Sound and keyboard")
                } footer: {
                    Text("The volume applies straight away. In the app: the speaker button, the Volume menu, or ⌘↑ ⌘↓ and ⌘0.")
                }
                Section {
                    Toggle("Keep the picture upright", isOn: $settings.lockCameraOrientation)
                    Toggle("Crop to a portrait frame", isOn: $settings.cropCameraToPortrait)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Turn these off for apps that expect a landscape camera, such as video calls.")
                }
                Section {
                    Toggle("Load tweaks", isOn: Binding(get: { !(appInfo["dontInjectTweakLoader"] as? Bool ?? false) },
                                                        set: { setOption(.dontInjectTweakLoader, $0 ? "off" : "on") }))
                        .disabled(appInfo["LCTweakLoaderCantInject"] as? Bool ?? false)
                    Picker("Tweak set", selection: Binding(get: { appInfo["LCTweakFolder"] as? String ?? "" },
                                                           set: { setOption(.tweakFolder, $0) })) {
                        Text("Global tweaks only").tag("")
                        ForEach(model.tweakFolders, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Hide LiveContainer from the app", isOn: flag(.hideLiveContainer))
                    LabeledContent("Language") {
                        TextField("System", text: $language, prompt: Text("System (e.g. fr)"))
                            .frame(width: 140).multilineTextAlignment(.trailing)
                            .onSubmit { setOption(.language, language) }
                    }
                    LabeledContent("Report iOS SDK version") {
                        TextField("Actual", text: $sdkVersion, prompt: Text("App's own (e.g. 16.0)"))
                            .frame(width: 140).multilineTextAlignment(.trailing)
                            .onSubmit { setOption(.spoofSDKVersion, sdkVersion.isEmpty ? "off" : sdkVersion) }
                    }
                } header: {
                    Text("LiveContainer")
                } footer: {
                    Text("Tweaks are .dylib files in LiveContainer's Tweaks folder; a tweak set is a subfolder. The SDK version changes behaviour that depends on which iOS an app was built for.")
                }
                Section {
                    if model.launchers.isInApplications(app) {
                        LabeledContent("In Applications") {
                            HStack {
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([model.launchers.url(for: app)]) }
                                Button("Remove") { model.perform(app) { try model.launchers.removeFromApplications(app) } }
                            }
                        }
                    } else {
                        LabeledContent("Mac app") {
                            Button("Add to Applications") {
                                model.perform(app) {
                                    let url = try model.launchers.addToApplications(app)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                    LabeledContent("Installed app") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Adds \(app.displayName) to your Applications folder for Launchpad, Spotlight and the Dock. It still runs through LiveContainer and uses the same containers.")
                }
                Section {
                    Button("Uninstall") { model.uninstall(app, deleteData: false); dismiss() }
                    Button("Uninstall and Delete Data…", role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text("Volume applies straight away; other changes the next time the app opens.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    setOption(.language, language)
                    setOption(.spoofSDKVersion, sdkVersion.isEmpty ? "off" : sdkVersion)
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500, height: 720)
        .onChange(of: settings) { _, value in app.settings = value }
        .alert("New Container", isPresented: $addingContainer) {
            TextField("Name", text: $containerName, prompt: Text("e.g. Work"))
            Button("Add") { model.addContainer(to: app, name: containerName.isEmpty ? "Container \(app.containers.count + 1)" : containerName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A fresh, empty copy of \(app.displayName)'s data.") }
        .confirmationDialog("Uninstall \(app.displayName) and delete its data?", isPresented: $confirmingDelete) {
            Button("Delete App and Data", role: .destructive) { model.uninstall(app, deleteData: true); dismiss() }
        } message: {
            Text("The app and all its containers, including logins and downloads inside the app, go to the Trash.")
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @State private var query = ""
    @State private var dropping = false
    @State private var configuring: LCApp?

    private var shown: [LCApp] {
        query.isEmpty ? model.apps : model.apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    Text("Drop an .ipa to get started").font(.title3.weight(.medium))
                    Text("LiveContainer runs decrypted iOS apps natively on this Mac, each with as many separate data containers as you like.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    Button("Choose a File…") { model.chooseFile() }.controlSize(.large).disabled(model.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).padding(24)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Apps").font(.title2.weight(.semibold))
                            Text("\(shown.count)").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14)], spacing: 14) {
                            ForEach(shown) { app in
                                AppCard(app: app, icon: model.icon(for: app),
                                        runningCount: app.containers.filter { model.running.contains($0.folderName) }.count,
                                        run: { model.run(app) }, configure: { configuring = app })
                                    .contextMenu { menu(for: app) }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center).ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if model.isBusy || !model.status.isEmpty {
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.status)
        .animation(.easeOut(duration: 0.18), value: model.isBusy)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            Menu("Tweaks", systemImage: "puzzlepiece.extension") {
                Button("Add Tweak…") { model.chooseTweak() }
                Button("Show Tweaks Folder") { NSWorkspace.shared.open(model.library.paths.tweaks) }
            }
            .help("Tweaks loaded into apps")
            Button("Install App", systemImage: "plus") { model.chooseFile() }
                .help("Install an .ipa")
                .disabled(model.isBusy)
        }
        .dropDestination(for: URL.self) { urls, _ in
            var handled = false
            for url in urls {
                switch url.pathExtension.lowercased() {
                case "ipa", "app": model.install(url); handled = true
                case "dylib", "framework": model.importTweak(url); handled = true
                default: break
                }
            }
            return handled
        } isTargeted: { dropping = $0 }
        .sheet(item: $configuring) { app in AppSettingsSheet(app: app, model: model) }
        .onChange(of: configuring) { _, value in if value == nil { model.reload() } }
        .alert("Something went wrong", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") {}
        } message: { Text(model.failure ?? "") }
        .onOpenURL { url in
            if ["ipa", "app"].contains(url.pathExtension.lowercased()) { model.install(url) }
        }
    }

    @ViewBuilder
    private func menu(for app: LCApp) -> some View {
        Button("Open") { model.run(app) }
        if app.containers.count > 1 {
            Menu("Open in Container") {
                ForEach(app.containers) { container in
                    Button(container.name + (model.running.contains(container.folderName) ? " (open)" : "")) { model.run(app, container: container) }
                }
            }
        }
        Button("Settings…") { configuring = app }
        Divider()
        Button("Show Data in Finder") {
            if let container = app.defaultContainer { NSWorkspace.shared.activateFileViewerSelecting([container.url.appendingPathComponent("Documents")]) }
        }
        if model.launchers.isInApplications(app) {
            Button("Remove from Applications") { model.perform(app) { try model.launchers.removeFromApplications(app) } }
        } else {
            Button("Add to Applications") { model.perform(app) { _ = try model.launchers.addToApplications(app) } }
        }
        Divider()
        Button("Uninstall") { model.uninstall(app, deleteData: false) }
    }
}

@main
struct LiveContainerApp: App {
    var body: some Scene {
        Window("LiveContainer", id: "main") { ContentView() }
            .defaultSize(width: 680, height: 500)
            .windowToolbarStyle(.unified)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
