import Foundation

/// An app's preference files in a container (Library/Preferences/*.plist), read and written
/// through cfprefsd with `defaults`. Writing the file directly does not work: cfprefsd keeps
/// its own copy, hands that to the app, and writes it back over the edit.
enum LCPreferences {
    static func files(in container: LCContainer) -> [URL] {
        let folder = container.url.appendingPathComponent("Library/Preferences")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func read(_ file: URL) throws -> [String: Any] {
        let xml = try Shell.run("/usr/bin/defaults", ["export", realPath(file), "-"])
        let object = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        return object as? [String: Any] ?? [:]
    }

    static func write(_ values: [String: Any], to file: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lc-prefs-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temp) }
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: temp)
        try Shell.run("/usr/bin/defaults", ["import", realPath(file), temp.path])
    }

    /// cfprefsd does not find a file spelled /var/folders/... (only /private/var/folders/...),
    /// so pass the real path. Foundation's resolvingSymlinksInPath drops /private, hence realpath.
    private static func realPath(_ file: URL) -> String {
        let folder = file.deletingLastPathComponent().path
        guard let resolved = realpath(folder, nil) else { return file.path }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + file.lastPathComponent
    }
}

/// One entry of a property list, as an editable tree.
final class PlistNode: Identifiable, ObservableObject {
    enum Kind: String, CaseIterable {
        case dictionary = "Dictionary", array = "Array", string = "String", integer = "Number",
             real = "Decimal", boolean = "Boolean", date = "Date", data = "Data"
    }

    let id = UUID()
    @Published var key: String
    @Published var kind: Kind
    @Published var string = ""
    @Published var number: Double = 0
    @Published var bool = false
    @Published var date = Date()
    var data = Data()
    @Published var children: [PlistNode]?          // dictionary and array only
    weak var parent: PlistNode?

    init(key: String, value: Any, parent: PlistNode? = nil) {
        self.key = key
        self.parent = parent
        switch value {
        case let dict as [String: Any]:
            kind = .dictionary
            children = []
            children = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { PlistNode(key: $0, value: dict[$0]!, parent: self) }
        case let array as [Any]:
            kind = .array
            children = []
            children = array.enumerated().map { PlistNode(key: "Item \($0.offset)", value: $0.element, parent: self) }
        case let value as Data: kind = .data; data = value
        case let value as Date: kind = .date; date = value
        case let value as String: kind = .string; string = value
        case let value as NSNumber:
            // NSNumber is also how property lists carry booleans.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { kind = .boolean; bool = value.boolValue }
            else if CFNumberIsFloatType(value) { kind = .real; number = value.doubleValue }
            else { kind = .integer; number = value.doubleValue }
        default:
            kind = .string; string = "\(value)"
        }
    }

    convenience init(kind: Kind, key: String, parent: PlistNode?) {
        let empty: Any = switch kind {
        case .dictionary: [String: Any]()
        case .array: [Any]()
        case .string: ""
        case .integer: 0
        case .real: 0.0
        case .boolean: false
        case .date: Date()
        case .data: Data()
        }
        self.init(key: key, value: empty, parent: parent)
    }

    var isContainer: Bool { kind == .dictionary || kind == .array }

    var value: Any {
        switch kind {
        case .dictionary:
            var result: [String: Any] = [:]
            for child in children ?? [] { result[child.key] = child.value }
            return result
        case .array: return (children ?? []).map(\.value)
        case .string: return string
        case .integer: return Int(number)
        case .real: return number
        case .boolean: return bool
        case .date: return date
        case .data: return data
        }
    }

    /// Adds an empty string entry, with a key not already in use.
    @discardableResult
    func addChild() -> PlistNode? {
        guard isContainer else { return nil }
        let used = Set((children ?? []).map(\.key))
        var key = kind == .array ? "Item \(children?.count ?? 0)" : "New Key"
        var n = 2
        while kind == .dictionary && used.contains(key) { key = "New Key \(n)"; n += 1 }
        let child = PlistNode(kind: .string, key: key, parent: self)
        children?.append(child)
        objectWillChange.send()
        return child
    }

    func remove() {
        parent?.children?.removeAll { $0 === self }
        parent?.renumber()
    }

    /// Changes the type, keeping the value where it converts (text <-> numbers, etc.).
    func change(to newKind: Kind) {
        guard newKind != kind else { return }
        let text = kind == .string ? string : kind == .boolean ? (bool ? "1" : "0") : String(number)
        kind = newKind
        switch newKind {
        case .dictionary, .array: children = []
        case .string: string = text; children = nil
        case .integer, .real: number = Double(text) ?? 0; children = nil
        case .boolean: bool = ["1", "true", "yes"].contains(text.lowercased()) || (Double(text) ?? 0) != 0; children = nil
        case .date, .data: children = nil
        }
    }

    /// A key used twice in one dictionary (saving would silently keep only one of them).
    var duplicateKey: String? {
        guard let children else { return nil }
        if kind == .dictionary {
            var seen = Set<String>()
            for child in children where !seen.insert(child.key).inserted { return child.key }
        }
        return children.lazy.compactMap(\.duplicateKey).first
    }

    private func renumber() {
        guard kind == .array else { return }
        for (index, child) in (children ?? []).enumerated() { child.key = "Item \(index)" }
    }
}
