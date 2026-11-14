import SwiftUI

// One app: header with Open, its containers, and its settings.

struct AppDetailView: View {
    let app: LCApp
    @ObservedObject var model: LibraryModel
    @Binding var path: [LCApp]
    @State private var settings: LCMacSettings
    @State private var appInfo: [String: Any]
    @State private var sdkVersion: String
    @State private var language: String
    @State private var addingContainer = false
    @State private var containerName = ""
    @State private var confirmingDelete = false
    @State private var size = ""

    init(app: LCApp, model: LibraryModel, path: Binding<[LCApp]>) {
        self.app = app
        self.model = model
        _path = path
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                containers
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
                    windowSettings
                    liveContainerSettings
                    cameraSettings
                    macSettings
                }
                dangerZone
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) { HeaderBackdrop(image: model.icon(for: app)) }
        .navigationTitle(app.displayName)
        .onChange(of: settings) { _, value in app.settings = value }
        .onDisappear { saveTextFields() }
        .task(id: model.revision) {
            let urls = [app.url] + app.containers.map(\.url)
            let bytes = await Task.detached { urls.reduce(0) { $0 + LCLibrary.size(of: $1) } }.value
            size = formattedSize(bytes)
        }
        .alert("New Container", isPresented: $addingContainer) {
            TextField("Name", text: $containerName, prompt: Text("e.g. Work"))
            Button("Add") { model.addContainer(to: app, name: containerName.isEmpty ? "Container \(app.containers.count + 1)" : containerName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A fresh, empty copy of \(app.displayName)'s data, with its own logins and keychain.") }
        .confirmationDialog("Uninstall \(app.displayName) and delete its data?", isPresented: $confirmingDelete) {
            Button("Delete App and Data", role: .destructive) { model.uninstall(app, deleteData: true); path.removeAll() }
        } message: {
            Text("The app and all its containers, including logins and downloads inside the app, go to the Trash.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            AppIconView(image: model.icon(for: app), size: 116)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(app.displayName).font(.system(size: 30, weight: .bold))
                    if model.isRunning(app) { StatusBadge(text: "Running", color: .green) }
                }
                Text(app.bundleIdentifier).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("Version \(app.version)")
                    if !size.isEmpty { Text("·"); Text(size) }
                    Text("·")
                    Text("\(app.containers.count) \(app.containers.count == 1 ? "container" : "containers")")
                }
                .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { model.run(app) } label: { Label("Open", systemImage: "play.fill").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    if app.containers.count > 1 {
                        Menu {
                            ForEach(app.containers) { container in
                                Button(container.name) { model.run(app, container: container) }
                            }
                        } label: { Label("Open in", systemImage: "square.stack") }
                        .controlSize(.large).fixedSize()
                    }
                    ViewThatFits(in: .horizontal) {
                        applicationsButton(compact: false)
                        applicationsButton(compact: true)
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private func applicationsButton(compact: Bool) -> some View {
        Button {
            if model.launchers.isInApplications(app) {
                NSWorkspace.shared.activateFileViewerSelecting([model.launchers.url(for: app)])
            } else {
                model.perform(app) { _ = try model.launchers.addToApplications(app) }
            }
        } label: {
            Label(model.launchers.isInApplications(app) ? "In Applications" : "Add to Applications",
                  systemImage: model.launchers.isInApplications(app) ? "checkmark.circle" : "square.and.arrow.down")
        }
        .labelStyle(CompactLabelStyle(compact: compact))
        .controlSize(.large)
        .help("Adds \(app.displayName) to your Applications folder for Launchpad, Spotlight and the Dock")
    }

    // MARK: Containers

    private var containers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Containers", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button { containerName = ""; addingContainer = true } label: { Label("Add Container", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(app.containers) { container in ContainerCard(app: app, container: container, model: model) }
            }
            Text("Each container is a separate copy of the app's data, with its own logins and keychain. Containers can be open at the same time, each in its own window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Settings

    private var windowSettings: some View {
        SettingsSection(title: "Window and Sound", systemImage: "macwindow") {
            SwitchRow("Hide the title bar", isOn: $settings.hideTitleBar)
            RowDivider()
            Picker("Size at launch", selection: $settings.windowSize) {
                Text("App decides").tag("default")
                Text("Phone").tag("phone")
                Text("Tablet").tag("tablet")
            }
            RowDivider()
            HStack(spacing: 8) {
                Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $settings.volume, in: 0...1, step: 0.05)
                Text("\(Int((settings.volume * 100).rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            RowDivider()
            SwitchRow("Volume button in the window", isOn: $settings.showVolumeButton)
            RowDivider()
            SwitchRow("Arrow keys move through feeds", isOn: $settings.arrowKeysScrollFeed)
        }
    }

    private var cameraSettings: some View {
        SettingsSection(title: "Camera", systemImage: "camera", footer: "Turn these off for apps that expect a landscape camera, such as video calls.") {
            SwitchRow("Keep the picture upright", isOn: $settings.lockCameraOrientation)
            RowDivider()
            SwitchRow("Crop to a portrait frame", isOn: $settings.cropCameraToPortrait)
        }
    }

    private var liveContainerSettings: some View {
        SettingsSection(title: "LiveContainer", systemImage: "shippingbox",
                        footer: "Changes apply the next time the app opens. The SDK version changes behaviour that depends on which iOS an app was built for.") {
            SwitchRow("Load tweaks", isOn: Binding(get: { !(appInfo["dontInjectTweakLoader"] as? Bool ?? false) },
                                                set: { setOption(.dontInjectTweakLoader, $0 ? "off" : "on") }))
                .disabled(appInfo["LCTweakLoaderCantInject"] as? Bool ?? false)
            RowDivider()
            Picker("Tweak set", selection: Binding(get: { appInfo["LCTweakFolder"] as? String ?? "" },
                                                   set: { setOption(.tweakFolder, $0) })) {
                Text("Global only").tag("")
                ForEach(model.tweakSets, id: \.self) { Text($0).tag($0) }
            }
            RowDivider()
            SwitchRow("Hide LiveContainer from the app", isOn: Binding(get: { appInfo["hideLiveContainer"] as? Bool ?? false },
                                                                   set: { setOption(.hideLiveContainer, $0 ? "on" : "off") }))
            RowDivider()
            LabeledContent("Language") {
                TextField("Language", text: $language, prompt: Text("System"))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .onSubmit { setOption(.language, language) }
            }
            RowDivider()
            LabeledContent("iOS SDK version") {
                TextField("SDK", text: $sdkVersion, prompt: Text("Actual"))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .onSubmit { setOption(.spoofSDKVersion, sdkVersion.isEmpty ? "off" : sdkVersion) }
            }
        }
    }

    private var macSettings: some View {
        SettingsSection(title: "Files", systemImage: "folder") {
            LabeledContent("Installed app") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            }
            RowDivider()
            LabeledContent("Launcher") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.launchers.url(for: app)]) }
            }
        }
    }

    private var dangerZone: some View {
        HStack {
            Button("Uninstall") { model.uninstall(app, deleteData: false); path.removeAll() }
                .help("Moves the app to the Trash and keeps its containers")
            Button("Uninstall and Delete Data…", role: .destructive) { confirmingDelete = true }
            Spacer()
        }
    }

    private func setOption(_ option: LCOption, _ value: String) {
        do {
            try model.library.setOption(option, value, app: app)
            appInfo = app.appInfo
        } catch {
            model.failure = "\(app.displayName): \(error)"
        }
    }

    private func saveTextFields() {
        if language != (appInfo["LCSelectedLanguage"] as? String ?? "") { setOption(.language, language) }
        setOption(.spoofSDKVersion, sdkVersion.isEmpty ? "off" : sdkVersion)
    }
}

/// The app's icon, blurred and faded, behind the header.
struct HeaderBackdrop: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(height: 280).frame(maxWidth: .infinity)
            .blur(radius: 70).saturation(1.4).opacity(0.35)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ContainerCard: View {
    let app: LCApp
    let container: LCContainer
    @ObservedObject var model: LibraryModel
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingReset = false
    @State private var confirmingRemove = false
    @State private var size = "…"

    var isDefault: Bool { container.folderName == app.defaultContainer?.folderName }
    var isRunning: Bool { model.running.contains(container.folderName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.square.fill").font(.title2).foregroundStyle(isRunning ? .green : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isDefault { StatusBadge(text: "Default") }
                if isRunning { StatusBadge(text: "Open", color: .green) }
            }
            HStack(spacing: 6) {
                if isRunning {
                    Button("Show") { model.launchers.activate(container) }
                    Button("Quit") { model.quit(container) }
                } else {
                    Button { model.run(app, container: container) } label: { Label("Open", systemImage: "play.fill") }
                }
                Spacer()
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
                .accessibilityLabel("More for \(container.name)")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isRunning ? Color.green.opacity(0.5) : Color.primary.opacity(0.08)))
        .task(id: model.revision) {
            let url = container.url
            let bytes = await Task.detached { LCLibrary.size(of: url) }.value
            size = formattedSize(bytes)
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
