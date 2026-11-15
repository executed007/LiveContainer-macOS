import SwiftUI

// Editor for an app's preference files in one container. Reads and saves through cfprefsd
// (LCPreferences), so changes reach the app even while it is running.

struct PlistEditorSheet: View {
    let app: LCApp
    let container: LCContainer
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var root: PlistNode?
    @State private var dirty = false
    @State private var message: String?
    @State private var pendingSelection: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preferences").font(.title3.weight(.semibold))
                    Text("\(app.displayName) · \(container.name)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                List(files, id: \.self, selection: Binding(get: { selection }, set: { select($0) })) { file in
                    Label(file.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(width: 240)
                Divider()
                editor
            }
            Divider()
            HStack {
                Text("Changes reach the app right away; some apps only read their settings at launch.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { load(selection) }.disabled(!dirty)
                Button("Save") { save() }.keyboardShortcut("s").disabled(!dirty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 600)
        .onAppear {
            files = LCPreferences.files(in: container)
            select(files.first { $0.lastPathComponent == app.bundleIdentifier + ".plist" } ?? files.first)
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Discard Changes", role: .destructive) { dirty = false; select(pendingSelection) }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let root {
            VStack(spacing: 0) {
                HStack {
                    Text("\(root.children?.count ?? 0) keys").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { root.addChild(); dirty = true } label: { Label("Add Key", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                List {
                    ForEach(root.children ?? []) { node in PlistNodeView(node: node, changed: { dirty = true }) }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView(files.isEmpty ? "No preferences yet" : "Choose a file", systemImage: "doc.text",
                                   description: Text(files.isEmpty ? "The app creates them the first time it saves a setting." : ""))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ file: URL?) {
        guard file != selection || root == nil else { return }
        if dirty { pendingSelection = file; return }
        pendingSelection = nil
        selection = file
        load(file)
    }

    private func load(_ file: URL?) {
        dirty = false
        guard let file else { root = nil; return }
        do {
            root = PlistNode(key: "", value: try LCPreferences.read(file))
            message = nil
        } catch {
            root = nil
            message = "Could not read \(file.lastPathComponent): \(error)"
        }
    }

    private func save() {
        guard let root, let selection, let values = root.value as? [String: Any] else { return }
        if let key = root.duplicateKey {
            message = "“\(key)” is used twice; rename one before saving"
            return
        }
        do {
            try LCPreferences.write(values, to: selection)
            dirty = false
            message = "Saved"
        } catch {
            message = "Could not save: \(error)"
        }
    }
}

/// One entry, with its children when it is a dictionary or array.
struct PlistNodeView: View {
    @ObservedObject var node: PlistNode
    let changed: () -> Void

    var body: some View {
        if node.isContainer {
            DisclosureGroup {
                ForEach(node.children ?? []) { child in PlistNodeView(node: child, changed: changed) }
            } label: { row }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Group {
                if node.parent?.kind == .array {
                    Text(node.key).foregroundStyle(.secondary)
                } else {
                    TextField("Key", text: $node.key).onChange(of: node.key) { _, _ in changed() }
                }
            }
            .frame(minWidth: 160, maxWidth: 260, alignment: .leading)
            Picker("Type", selection: Binding(get: { node.kind }, set: { node.change(to: $0); changed() })) {
                ForEach(PlistNode.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .textFieldStyle(.plain)
        .contextMenu {
            if node.isContainer { Button("Add Item") { node.addChild(); changed() } }
            if node.parent != nil { Button("Delete", role: .destructive) { node.remove(); changed() } }
        }
    }

    @ViewBuilder
    private var value: some View {
        switch node.kind {
        case .dictionary, .array:
            Text("\(node.children?.count ?? 0) items").foregroundStyle(.secondary)
        case .string:
            TextField("Value", text: $node.string).onChange(of: node.string) { _, _ in changed() }
        case .integer, .real:
            TextField("Value", value: $node.number, format: .number).onChange(of: node.number) { _, _ in changed() }
        case .boolean:
            Toggle("Value", isOn: $node.bool).labelsHidden().onChange(of: node.bool) { _, _ in changed() }
        case .date:
            DatePicker("Value", selection: $node.date).labelsHidden().onChange(of: node.date) { _, _ in changed() }
        case .data:
            Text("\(node.data.count) bytes").foregroundStyle(.secondary).help("Data values are shown, not edited")
        }
    }
}
