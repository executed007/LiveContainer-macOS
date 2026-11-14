import SwiftUI

// The main window: a sidebar (Apps, Running, Tweaks) and the selected page.

enum SidebarItem: Hashable {
    case apps, running, tweaks
}

struct RootView: View {
    @StateObject private var model = LibraryModel()
    @State private var selection: SidebarItem? = .apps
    @State private var path: [LCApp] = []
    @State private var dropping = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Apps", systemImage: "square.grid.2x2").badge(model.apps.count).tag(SidebarItem.apps)
                    Label("Running", systemImage: "play.circle").badge(model.runningApps.count).tag(SidebarItem.running)
                }
                Section("Customize") {
                    Label("Tweaks", systemImage: "puzzlepiece.extension").badge(model.tweaks.count).tag(SidebarItem.tweaks)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter(model: model) }
        } detail: {
            NavigationStack(path: $path) {
                page
                    .navigationDestination(for: LCApp.self) { app in AppDetailView(app: app, model: model, path: $path) }
            }
        }
        .onChange(of: selection) { _, _ in path.removeAll() }
        .overlay(alignment: .bottom) { ActivityOverlay(model: model) }
        .overlay { if dropping { DropOverlay() } }
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
        .alert("Something went wrong", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") {}
        } message: { Text(model.failure ?? "") }
        .onOpenURL { url in
            if ["ipa", "app"].contains(url.pathExtension.lowercased()) { model.install(url) }
        }
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 500, idealHeight: 680)
        .onAppear(perform: sizeWindowOnFirstLaunch)
    }

    /// The first window opens at a comfortable size; after that macOS restores the user's.
    private func sizeWindowOnFirstLaunch() {
        let key = "LCMacSizedFirstWindow"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.center()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection ?? .apps {
        case .apps: AppsGridView(model: model, path: $path, apps: model.apps, title: "Apps")
        case .running: AppsGridView(model: model, path: $path, apps: model.runningApps, title: "Running")
        case .tweaks: TweaksView(model: model)
        }
    }
}

struct SidebarFooter: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        let containers = model.apps.reduce(0) { $0 + $1.containers.count }
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("LiveContainer").font(.caption.weight(.semibold))
                Text("\(model.apps.count) apps · \(containers) containers").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(model.library.paths.documents) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show LiveContainer's folder in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Grid

struct AppsGridView: View {
    @ObservedObject var model: LibraryModel
    @Binding var path: [LCApp]
    let apps: [LCApp]
    let title: String
    @State private var query = ""

    private var shown: [LCApp] {
        query.isEmpty ? apps : apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if apps.isEmpty {
                if title == "Running" {
                    ContentUnavailableView("Nothing running", systemImage: "play.circle",
                                           description: Text("Apps you open from LiveContainer show up here, with each open container."))
                } else {
                    WelcomeView(model: model)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 18) {
                        ForEach(shown) { app in
                            AppCard(app: app, icon: model.icon(for: app), isRunning: model.isRunning(app),
                                    open: { model.run(app) }, show: { path.append(app) })
                                .contextMenu { AppMenu(app: app, model: model, path: $path) }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(apps.isEmpty ? "" : "\(apps.count) \(apps.count == 1 ? "app" : "apps")")
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseApp() } label: { Label("Install App", systemImage: "plus") }
                    .help("Install an .ipa").disabled(model.isBusy)
            }
        }
    }
}

struct AppCard: View {
    let app: LCApp
    let icon: NSImage
    let isRunning: Bool
    let open: () -> Void
    let show: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            AppIconView(image: icon, size: 92)
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.04 : 1)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    if isRunning { RunningDot() }
                    Text(app.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                }
                let containers = app.containers.count
                Text(containers > 1 ? "\(app.shortVersion) · \(containers) containers" : app.shortVersion)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20).padding(.bottom, 14).padding(.horizontal, 10)
        .background(.background.secondary.opacity(hovering ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.12 : 0.05)))
        .overlay(alignment: .topTrailing) {
            Button(action: open) {
                Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help("Open \(app.displayName)")
            .accessibilityLabel("Open \(app.displayName)")
            .padding(10)
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: show)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, show)
        .accessibilityAction(named: "Open", open)
    }
}

struct AppMenu: View {
    let app: LCApp
    @ObservedObject var model: LibraryModel
    @Binding var path: [LCApp]

    var body: some View {
        Button("Open") { model.run(app) }
        if app.containers.count > 1 {
            Menu("Open in Container") {
                ForEach(app.containers) { container in
                    Button(container.name + (model.running.contains(container.folderName) ? " (open)" : "")) {
                        model.run(app, container: container)
                    }
                }
            }
        }
        Button("Show Details") { path.append(app) }
        Divider()
        if model.launchers.isInApplications(app) {
            Button("Remove from Applications") { model.perform(app) { try model.launchers.removeFromApplications(app) } }
        } else {
            Button("Add to Applications") { model.perform(app) { _ = try model.launchers.addToApplications(app) } }
        }
        Button("Show Data in Finder") {
            if let container = app.defaultContainer {
                NSWorkspace.shared.activateFileViewerSelecting([container.url.appendingPathComponent("Documents")])
            }
        }
        Divider()
        Button("Uninstall") { model.uninstall(app, deleteData: false) }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 112, height: 112)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 18, y: 8)
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 50, weight: .medium)).foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Welcome to LiveContainer").font(.largeTitle.weight(.bold))
                Text("Run iOS apps natively on your Mac, each with as many separate data containers as you like.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack(alignment: .top, spacing: 28) {
                Feature(icon: "arrow.down.app", title: "Drop an .ipa", text: "Any decrypted iOS app installs in seconds.")
                Feature(icon: "person.2.crop.square.stack", title: "Containers", text: "Separate logins, side by side.")
                Feature(icon: "macwindow", title: "Mac windows", text: "Every app in its own window and Dock icon.")
            }
            .frame(maxWidth: 560)
            Button { model.chooseApp() } label: { Label("Install an App…", systemImage: "plus").padding(.horizontal, 8) }
                .controlSize(.large).buttonStyle(.borderedProminent).disabled(model.isBusy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    struct Feature: View {
        let icon: String, title: String, text: String
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(height: 28)
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
