import Foundation

/// LiveContainer's executable patch (LCPatchExecSlice in LiveContainer/LCMachOUtils.m),
/// ported to Swift so the installer can run it on thin slices in memory:
///
/// - MH_EXECUTE becomes MH_DYLIB, so the runtime can dlopen the app's executable.
/// - __PAGEZERO shrinks to one page below 4 GiB, so it fits next to the launcher's own.
/// - An LC_ID_DYLIB is added (first, as dylibify does) when the executable has none.
/// - An LC_LOAD_DYLIB for TweakLoader is added, or a placeholder when injection is off.
/// - Duplicate dylib dependencies, which dyld refuses, are disabled.
extension MachO {
    static let lcIDDylib: UInt32 = 0xd
    static let lcLoadDylinker: UInt32 = 0xe
    static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    static let lcReexportDylib: UInt32 = 0x8000_001f
    static let lcLoadUpwardDylib: UInt32 = 0x8000_0023
    static let lcCodeSignature: UInt32 = 0x1d
    static let lcMain: UInt32 = 0x8000_0028
    static let lcDyldChainedFixups: UInt32 = 0x8000_0034
    /// Upstream's placeholder command: a TweakLoader slot that dyld ignores.
    static let lcPlaceholder: UInt32 = 0x114514
    static let lcDisabledDuplicate: UInt32 = 0x114515

    static let mhExecute: UInt32 = 2
    static let mhDylib: UInt32 = 6
    static let mhPIE: UInt32 = 0x0020_0000
    static let mhNoReexportedDylibs: UInt32 = 0x0010_0000

    /// Upstream's path, relative to the app's executable in Documents/Applications/<app>/.
    static let tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib"
    static let placeholderPath = "/usr/lib/libc++.1.dylib"

    struct LiveContainerPatchResult: OptionSet {
        let rawValue: Int
        /// No room in the header for the TweakLoader command; tweaks are loaded later instead.
        static let noSpaceForTweakLoader = LiveContainerPatchResult(rawValue: 1)
        /// Segment count differs from the chained fixups table (needs a dyld workaround on iOS 27).
        static let segCountMismatch = LiveContainerPatchResult(rawValue: 2)
    }

    /// Applies the patch to a thin 64-bit slice. `name` becomes the LC_ID_DYLIB install name.
    static func patchedForLiveContainer(_ thin: Data, name: String, injectTweakLoader: Bool) throws
        -> (Data, LiveContainerPatchResult) {
        guard thin.count >= headerSize, thin.u32(0) == magic64 else { throw Failure.notMachO }
        var data = thin
        var result: LiveContainerPatchResult = []

        data.setU32(mhDylib, at: 12)
        data.setU32((data.u32(24) | mhNoReexportedDylibs) & ~mhPIE, at: 24)

        var commands = try MachO.commands(data)
        if let first = commands.first, first.cmd == lcSegment64, data.u64(first.range.lowerBound + 24) == 0 {
            data.setU64(0x1_0000_0000 - 0x4000, at: first.range.lowerBound + 24)   // vmaddr
            data.setU64(0x4000, at: first.range.lowerBound + 32)                   // vmsize
        }

        var hasIDDylib = false, hasSignature = false, segmentCount: UInt32 = 0
        var tweakLoaderCommand: Command?, dylinker: Command?
        var textSectionOffset = data.count
        for command in commands {
            let base = command.range.lowerBound
            switch command.cmd {
            case lcIDDylib: hasIDDylib = true
            case lcLoadDylib where loadPath(data, command).hasPrefix(tweakLoaderPath): tweakLoaderCommand = command
            case lcPlaceholder: tweakLoaderCommand = command
            case lcCodeSignature: hasSignature = true
            case lcLoadDylinker: dylinker = command
            case lcSegment64:
                segmentCount += 1
                if segmentName(data, at: base + 8) == "__TEXT" {
                    for index in 0..<Int(data.u32(base + 64)) {
                        let section = base + 72 + index * 80
                        if segmentName(data, at: section) == "__text" { textSectionOffset = Int(data.u32(section + 48)) }
                    }
                }
            case lcDyldChainedFixups:
                if segmentCount != chainedFixupsSegmentCount(data, command) { result.insert(.segCountMismatch) }
            default: break
            }
        }

        var free = textSectionOffset - (headerSize + Int(data.u32(20)))
        if !hasSignature { free -= 16 }       // codesign adds LC_CODE_SIGNATURE later

        if !hasIDDylib {
            let idName = Data(name.utf8)
            let size = 24 + roundUp8(idName.count + 1)
            if free >= size {
                free -= size
                insertCommand(&data, dylibCommand(lcIDDylib, name: idName, size: size), atStart: true)
            } else if let dylinker {
                // Upstream's fix for #1042: reuse LC_LOAD_DYLINKER's slot when there is no room.
                let size = dylinker.range.count
                var replacement = dylibCommand(lcIDDylib, name: Data(), size: size)
                let room = size - 24
                replacement.replaceSubrange(24 ..< 24 + min(room - 1, idName.count), with: idName.prefix(room - 1))
                data.replaceSubrange(data.startIndex + dylinker.range.lowerBound ..< data.startIndex + dylinker.range.upperBound,
                                     with: replacement)
            }
            commands = try MachO.commands(data)
            tweakLoaderCommand = commands.first {
                $0.cmd == lcPlaceholder || ($0.cmd == lcLoadDylib && loadPath(data, $0).hasPrefix(tweakLoaderPath))
            }
        }

        let loaderPath = Data((injectTweakLoader ? tweakLoaderPath : placeholderPath).utf8)
        let loaderCmd = injectTweakLoader ? lcLoadDylib : lcPlaceholder
        if let existing = tweakLoaderCommand {
            let base = existing.range.lowerBound
            data.setU32(loaderCmd, at: base)
            let nameStart = base + Int(data.u32(base + 8))
            let room = existing.range.upperBound - nameStart
            var name = loaderPath.prefix(room - 1)
            name.append(Data(count: room - name.count))
            data.replaceSubrange(data.startIndex + nameStart ..< data.startIndex + existing.range.upperBound, with: name)
        } else if free >= 0x48 {
            insertCommand(&data, dylibCommand(loaderCmd, name: loaderPath, size: 0x48), atStart: false)
        } else {
            result.insert(.noSpaceForTweakLoader)
        }

        // dyld rejects a binary that loads the same dylib twice (upstream #582).
        var seen = Set<String>()
        for command in try MachO.commands(data)
        where [lcLoadDylib, lcLoadWeakDylib, lcReexportDylib, lcLoadUpwardDylib].contains(command.cmd) {
            let path = loadPath(data, command)
            if !seen.insert(path).inserted { data.setU32(lcDisabledDuplicate, at: command.range.lowerBound) }
        }
        return (data, result)
    }

    /// True for an executable that LiveContainer has not patched yet.
    static func isExecutable(_ thin: Data) -> Bool { thin.count >= headerSize && thin.u32(12) == mhExecute }

    static func hasMainEntryPoint(_ thin: Data) -> Bool { (try? commands(thin).contains { $0.cmd == lcMain }) ?? false }

    // MARK: - Helpers

    private static func roundUp8(_ value: Int) -> Int { (value + 7) & ~7 }

    private static func segmentName(_ data: Data, at offset: Int) -> String {
        String(decoding: data.slice(offset ..< offset + 16).prefix { $0 != 0 }, as: UTF8.self)
    }

    static func loadPath(_ data: Data, _ command: Command) -> String {
        let base = command.range.lowerBound
        let offset = Int(data.u32(base + 8))
        guard offset >= 24, base + offset < command.range.upperBound else { return "" }
        return String(decoding: data.slice(base + offset ..< command.range.upperBound).prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func dylibCommand(_ cmd: UInt32, name: Data, size: Int) -> Data {
        var command = Data()
        for value in [cmd, UInt32(size), 24, 2, 0x0001_0000, 0x0001_0000] { command.append(u32: value) }
        command.append(name)
        command.append(Data(count: size - command.count))
        return command
    }

    private static func insertCommand(_ data: inout Data, _ command: Data, atStart: Bool) {
        let tableEnd = headerSize + Int(data.u32(20))
        let start = data.startIndex
        if atStart {
            let table = data.slice(headerSize ..< tableEnd)
            data.replaceSubrange(start + headerSize ..< start + tableEnd + command.count, with: command + table)
        } else {
            data.replaceSubrange(start + tableEnd ..< start + tableEnd + command.count, with: command)
        }
        data.setU32(data.u32(16) + 1, at: 16)
        data.setU32(data.u32(20) + UInt32(command.count), at: 20)
    }

    private static func chainedFixupsSegmentCount(_ data: Data, _ command: Command) -> UInt32 {
        let base = command.range.lowerBound
        let dataOffset = Int(data.u32(base + 8)), dataSize = Int(data.u32(base + 12))
        guard dataOffset > 0, dataSize >= 28, dataOffset + 8 <= data.count else { return 0 }
        let startsOffset = Int(data.u32(dataOffset + 4))
        guard startsOffset > 0, startsOffset + 4 <= dataSize, dataOffset + startsOffset + 4 <= data.count else { return 0 }
        return data.u32(dataOffset + startsOffset)
    }
}

extension Data {
    mutating func setU64(_ value: UInt64, at offset: Int) {
        setU32(UInt32(truncatingIfNeeded: value), at: offset)
        setU32(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }
}
