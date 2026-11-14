import SwiftUI

// The Tweaks page: global tweaks load into every app; a tweak set loads into the apps that
// choose it in their settings.

struct TweaksView: View {
    @ObservedObject var model: LibraryModel
    @State private var addingSet = false
    @State private var setName = ""

    private var groups: [(title: String, set: String?, items: [TweakItem])] {
        var result: [(String, String?, [TweakItem])] = [("Global", nil, model.tweaks.filter { $0.set == nil })]
        for set in model.tweakSets { result.append((set, set, model.tweaks.filter { $0.set == set })) }
        return result
    }

    var body: some View {
        Group {
            if model.tweaks.isEmpty && model.tweakSets.isEmpty {
                ContentUnavailableView {
                    Label("No tweaks", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Tweaks are .dylib or .framework files loaded into apps, with CydiaSubstrate available. Drop one here or add it. iOS tweaks are converted for this Mac.")
                } actions: {
                    Button("Add Tweak…") { model.chooseTweak() }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(groups, id: \.title) { group in
                            TweakGroup(model: model, title: group.title, set: group.set, items: group.items)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Tweaks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { setName = ""; addingSet = true } label: { Label("New Tweak Set", systemImage: "folder.badge.plus") }
                    .help("A folder of tweaks that individual apps can load")
                Button { model.chooseTweak() } label: { Label("Add Tweak", systemImage: "plus") }
                    .help("Add a global tweak")
            }
        }
        .alert("New Tweak Set", isPresented: $addingSet) {
            TextField("Name", text: $setName)
            Button("Create") { model.addTweakSet(setName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose the set in an app's settings to load its tweaks into that app.") }
    }
}

struct TweakGroup: View {
    @ObservedObject var model: LibraryModel
    let title: String
    let set: String?
    let items: [TweakItem]

    private var footer: String {
        guard let set else { return "Loaded into every app that has tweaks on." }
        let users = model.apps.filter { $0.appInfo["LCTweakFolder"] as? String == set }.map(\.displayName)
        return users.isEmpty ? "Not used by any app yet. Choose it in an app's settings." : "Used by " + users.joined(separator: ", ") + "."
    }

    var body: some View {
        SettingsSection(title: title, systemImage: set == nil ? "globe" : "folder", footer: footer) {
            if items.isEmpty {
                HStack {
                    Text("No tweaks in this set").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add…") { model.chooseTweak(folder: set) }.buttonStyle(.borderless)
                }
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, tweak in
                if index > 0 { RowDivider() }
                HStack(spacing: 10) {
                    Image(systemName: tweak.kind == "Framework" ? "shippingbox.fill" : "puzzlepiece.extension.fill")
                        .foregroundStyle(tweak.isEnabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tweak.name).fontWeight(.medium).foregroundStyle(tweak.isEnabled ? .primary : .secondary)
                        Text(tweak.kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { tweak.isEnabled }, set: { model.setEnabled(tweak, $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tweak.url]) }
                    Button("Remove", role: .destructive) { model.remove(tweak) }
                }
            }
            if set != nil, !items.isEmpty {
                RowDivider()
                Button { model.chooseTweak(folder: set) } label: { Label("Add to \(title)…", systemImage: "plus") }.buttonStyle(.borderless)
            }
        }
    }
}
