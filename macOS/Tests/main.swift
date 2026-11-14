import Foundation

// Unit tests on synthetic images: MachO.swift (from Catalyst Runner), the LiveContainer
// executable patch, and the library model. Run by build.sh.

var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    let passed = (try? condition()) ?? false
    print("\(passed ? "ok  " : "FAIL") \(name)")
    if !passed { failures += 1 }
}

func words(_ values: [UInt32]) -> Data {
    var data = Data()
    values.forEach { data.append(u32: $0) }
    return data
}

/// A thin arm64 image: header, the given load commands, zero padding up to `contentOffset`,
/// then 64 bytes of "code". One __TEXT segment with one section points at that code.
func image(versionCommand: Data, extra: [Data] = [], contentOffset: UInt32 = 512) -> Data {
    var segment = words([MachO.lcSegment64, 72 + 80])
    segment.append(Data(count: 64))                       // segname..flags, zeroed
    segment.setU32(1, at: 64)                             // nsects
    var section = Data(count: 80)
    section.setU32(64, at: 40)                            // size
    section.setU32(contentOffset, at: 48)                 // offset
    segment.append(section)
    let commands = [segment, versionCommand] + extra
    let size = commands.reduce(0) { $0 + $1.count }
    var data = words([MachO.magic64, MachO.cpuArm64, 0, 2, UInt32(commands.count), UInt32(size), 0, 0])
    commands.forEach { data.append($0) }
    data.append(Data(count: Int(contentOffset) - data.count))
    data.append(Data(repeating: 0xAA, count: 64))
    return data
}

let iosBuild = words([MachO.lcBuildVersion, 32, 2, 0x000e_0000, 0x0011_0000, 1, 3, 0x0300_0000])   // iOS 14, one tool
let iosVersionMin = words([MachO.lcVersionMinIOS, 16, 0x000c_0000, 0x000e_0000])
let trailing = words([0x1b, 24, 1, 2, 3, 4])                                                       // LC_UUID
func encryption(cryptid: UInt32) -> Data { words([MachO.lcEncryptionInfo64, 24, 0x4000, 0x1000, cryptid, 0]) }

// LC_BUILD_VERSION (iOS) -> Mac Catalyst
do {
    let source = image(versionCommand: iosBuild, extra: [trailing])
    let output = try MachO.replacingVersionCommand(source)
    check(try MachO.buildVersion(output) == MachO.catalyst, "LC_BUILD_VERSION becomes Mac Catalyst 11.0 / sdk 14.0")
    check(try MachO.commands(output).map(\.cmd) == [MachO.lcSegment64, MachO.lcBuildVersion, 0x1b], "command order kept")
    check(output.u32(20) == source.u32(20) - 8, "sizeofcmds shrinks by the dropped tool entry")
    check(output.count == source.count && output.suffix(64) == source.suffix(64), "file size and code untouched")
    check(output.slice(32 + Int(output.u32(20)) ..< 512).allSatisfy { $0 == 0 }, "stale command bytes zeroed")
    check(try MachO.commands(output).last.map { output.slice($0.range) } == trailing, "following command moved intact")
    check(try MachO.replacingVersionCommand(output) == output, "conversion is idempotent")
} catch { check(false, "build-version conversion threw \(error)") }

// LC_VERSION_MIN_IPHONEOS (16 bytes) -> LC_BUILD_VERSION (24 bytes)
do {
    let source = image(versionCommand: iosVersionMin, extra: [trailing])
    let output = try MachO.replacingVersionCommand(source)
    check(try MachO.buildVersion(output) == MachO.catalyst, "LC_VERSION_MIN_IPHONEOS replaced")
    check(output.u32(20) == source.u32(20) + 8 && output.u32(16) == source.u32(16), "table grows into header padding")
    let tight = image(versionCommand: iosVersionMin, contentOffset: UInt32(32 + 152 + 16))
    check((try? MachO.replacingVersionCommand(tight)) == nil, "refuses to overwrite code when there is no padding")
} catch { check(false, "version-min conversion threw \(error)") }

// Encryption
check(try MachO.isEncrypted(image(versionCommand: iosBuild, extra: [encryption(cryptid: 1)])), "cryptid 1 detected as encrypted")
check(try !MachO.isEncrypted(image(versionCommand: iosBuild, extra: [encryption(cryptid: 0)])), "cryptid 0 is not encrypted")
do {
    _ = try MachO.convertedToCatalyst(image(versionCommand: iosBuild, extra: [encryption(cryptid: 1)]))
    check(false, "encrypted binary rejected")
} catch MachO.Failure.encrypted { check(true, "encrypted binary rejected") } catch { check(false, "encrypted binary rejected") }

// Fat binaries are thinned to arm64
do {
    let arm = image(versionCommand: iosBuild)
    var fat = Data()
    for value in [MachO.fatMagic, 2, 0x0100_0007, 3, 64, 16, 0, MachO.cpuArm64, 0, 128, UInt32(arm.count), 0] as [UInt32] {
        fat.append(u32: value.byteSwapped)
    }
    fat.append(Data(count: 128 - fat.count))
    fat.append(arm)
    _ = try MachO.thinned(fat)
    check(try MachO.thinned(fat) == arm, "arm64 slice extracted from fat binary")
    check(try MachO.buildVersion(MachO.convertedToCatalyst(fat)) == MachO.catalyst, "fat binary converted")
    check(MachO.isMachO(fat) && MachO.isMachO(arm) && !MachO.isMachO(Data(count: 64)), "Mach-O detection")
} catch { check(false, "fat handling threw \(error)") }

// Helper library injection
do {
    let source = image(versionCommand: iosBuild)
    let path = "@executable_path/Frameworks/RunnerShim.dylib"
    let output = try MachO.addingDylib(source, path: path)
    let added = try MachO.commands(output).last!
    check(added.cmd == MachO.lcLoadDylib && added.range.count % 8 == 0, "LC_LOAD_DYLIB appended")
    check(output.slice(added.range.lowerBound + 24 ..< added.range.upperBound).prefix(path.utf8.count) == Data(path.utf8), "dylib path stored")
    check(output.u32(16) == source.u32(16) + 1 && output.suffix(64) == source.suffix(64), "command count bumped, code untouched")
    check(try MachO.addingDylib(output, path: path) == output, "injection is idempotent")
    let tight = image(versionCommand: iosBuild, contentOffset: UInt32(32 + 152 + 32 + 16))
    check((try? MachO.addingDylib(tight, path: path)) == nil, "injection refused without header padding")
} catch { check(false, "dylib injection threw \(error)") }

// Corruption
do {
    var broken = image(versionCommand: iosBuild)
    broken.setU32(0xffff, at: 20)
    check((try? MachO.commands(broken)) == nil, "oversized sizeofcmds rejected")
    check((try? MachO.thinned(Data("not a binary at all, just some text".utf8))) == nil, "non Mach-O rejected")
}


// MARK: - LiveContainer executable patch

func named(_ name: String) -> Data { var d = Data(name.utf8); d.append(Data(count: 16 - d.count)); return d }

/// An executable like the linker makes: __PAGEZERO, __TEXT with a __text section, LC_MAIN.
func executable(contentOffset: UInt32 = 1024, extra: [Data] = []) -> Data {
    var pageZero = words([MachO.lcSegment64, 72]); pageZero.append(named("__PAGEZERO"))
    pageZero.append(words([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]))           // vmaddr 0, vmsize 4 GiB
    var text = words([MachO.lcSegment64, 72 + 80]); text.append(named("__TEXT")); text.append(Data(count: 48))
    text.setU32(1, at: 64)
    var section = Data(count: 80)
    section.replaceSubrange(0..<16, with: named("__text")); section.setU32(64, at: 40); section.setU32(contentOffset, at: 48)
    text.append(section)
    let main = words([MachO.lcMain, 24, contentOffset, 0, 0, 0])
    let commands = [pageZero, text, iosBuild, main] + extra
    let size = commands.reduce(0) { $0 + $1.count }
    var data = words([MachO.magic64, MachO.cpuArm64, 0, MachO.mhExecute, UInt32(commands.count), UInt32(size), MachO.mhPIE, 0])
    commands.forEach { data.append($0) }
    data.append(Data(count: Int(contentOffset) - data.count))
    data.append(Data(repeating: 0xAA, count: 64))
    return data
}

func dylibLoad(_ path: String) -> Data {
    let size = (24 + path.utf8.count + 1 + 7) & ~7
    var d = words([MachO.lcLoadDylib, UInt32(size), 24, 2, 0x10000, 0x10000]); d.append(Data(path.utf8)); d.append(Data(count: size - d.count))
    return d
}

do {
    let source = executable()
    check(MachO.isExecutable(source) && MachO.hasMainEntryPoint(source), "fixture is an executable with LC_MAIN")
    let (output, result) = try MachO.patchedForLiveContainer(source, name: "App", injectTweakLoader: true)
    let commands = try MachO.commands(output)
    check(output.u32(12) == MachO.mhDylib, "MH_EXECUTE becomes MH_DYLIB")
    check(output.u32(24) & MachO.mhPIE == 0 && output.u32(24) & MachO.mhNoReexportedDylibs != 0, "PIE cleared, NO_REEXPORTED_DYLIBS set")
    check(commands.first?.cmd == MachO.lcIDDylib && MachO.loadPath(output, commands[0]) == "App", "LC_ID_DYLIB inserted first")
    let pageZero = commands[1].range.lowerBound
    check(output.u64(pageZero + 24) == 0xFFFF_C000 && output.u64(pageZero + 32) == 0x4000, "__PAGEZERO shrunk to one page below 4 GiB")
    check(commands.contains { $0.cmd == MachO.lcLoadDylib && MachO.loadPath(output, $0) == MachO.tweakLoaderPath }, "TweakLoader load command added")
    check(result.isEmpty, "no warnings for a roomy header")
    check(output.count == source.count && output.suffix(64) == source.suffix(64), "file size and code untouched")
    let (again, _) = try MachO.patchedForLiveContainer(output, name: "App", injectTweakLoader: true)
    check(again == output, "patch is idempotent")

    let (off, _) = try MachO.patchedForLiveContainer(source, name: "App", injectTweakLoader: false)
    let placeholder = try MachO.commands(off).first { $0.cmd == MachO.lcPlaceholder }
    check(placeholder.map { MachO.loadPath(off, $0) } == MachO.placeholderPath, "tweaks off: placeholder slot instead of TweakLoader")
    let (on, _) = try MachO.patchedForLiveContainer(off, name: "App", injectTweakLoader: true)
    check(try MachO.commands(on).filter { $0.cmd == MachO.lcLoadDylib }.map { MachO.loadPath(on, $0) } == [MachO.tweakLoaderPath],
          "turning tweaks back on reuses the slot")

    let duplicated = executable(extra: [dylibLoad("/usr/lib/libz.1.dylib"), dylibLoad("/usr/lib/libz.1.dylib")])
    let (deduped, _) = try MachO.patchedForLiveContainer(duplicated, name: "App", injectTweakLoader: true)
    check(try MachO.commands(deduped).filter { $0.cmd == MachO.lcDisabledDuplicate }.count == 1, "duplicate dylib dependency disabled")

    let tightOffset: UInt32 = 32 + 72 + 152 + 32 + 24 + 8
    let tight = executable(contentOffset: tightOffset)
    let (tightOut, tightResult) = try MachO.patchedForLiveContainer(tight, name: "App", injectTweakLoader: true)
    check(tightResult.contains(MachO.LiveContainerPatchResult.noSpaceForTweakLoader) && tightOut.suffix(64) == tight.suffix(64), "no header room: reported, code untouched")
} catch { check(false, "LiveContainer patch threw \(error)") }

// MARK: - Library model

do {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("lcmac-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let library = LCLibrary(paths: LCPaths(home: home))
    try library.paths.createFolders()
    let appURL = library.paths.applications.appendingPathComponent("com.example.app.app")
    try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    try LCPlist.write(["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "2.0"],
                      to: appURL.appendingPathComponent("Info.plist"))
    try LCPlist.write([:], to: appURL.appendingPathComponent("LCAppInfo.plist"))
    let app = try XCTUnwrap(library.app("com.example.app"))
    check(library.app("Example") == app && library.app("com.example.app.app") == app, "apps found by identifier, name or folder")
    let first = try library.addContainer(to: app, name: "Default")
    let second = try library.addContainer(to: app, name: "Work")
    check(app.containers.map(\.name) == ["Default", "Work"] && app.defaultContainer == first, "containers added, first is default")
    check(FileManager.default.fileExists(atPath: second.url.appendingPathComponent("Library/Preferences").path), "container gets an iOS home layout")
    library.setDefaultContainer(second, of: app)
    check(app.defaultContainer?.folderName == second.folderName, "default container changed")
    library.renameContainer(second, of: app, to: "Personal")
    check(app.container(named: "personal")?.folderName == second.folderName, "rename, case-insensitive lookup")
    check(!first.isRunning, "a closed container is not running")
    try library.setOption(.spoofSDKVersion, "16.4", app: app)
    check(app.appInfo["spoofSDKVersion"] as? UInt32 == 0x10_0400 || app.appInfo["spoofSDKVersion"] as? Int == 0x10_0400, "SDK version encoded like dyld (16.4 = 0x100400)")
    try library.setOption(.hideLiveContainer, "on", app: app)
    check(app.appInfo["hideLiveContainer"] as? Bool == true, "boolean option stored under upstream's key")
    try library.setOption(.spoofIdentifierForVendor, "on", app: app, container: first)
    check(first.info["spoofIdentifierForVendor"] as? Bool == true && first.info["spoofedIdentifierForVendor"] is String, "container option gets a fixed IDFV")
    check((try? library.setOption(.hideLiveContainer, "maybe", app: app)) == nil, "invalid value rejected")
    try library.removeContainer(first, from: app)
    check(app.containers.count == 1 && (try? library.removeContainer(second, from: app)) == nil, "removing works, the last container stays")
    var settings = app.settings
    check(settings == LCMacSettings(), "Mac settings default when unset")
    settings.volume = 0.4
    app.settings = settings
    check(app.settings.volume == 0.4, "Mac settings saved")
} catch { check(false, "library model threw \(error)") }

func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw LCError.message("unexpected nil") }
    return value
}

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
