// Build-time helper: makes AppIcon.icns from upstream's 1024 px icon with MacIcon.swift.
import Foundation
let arguments = CommandLine.arguments
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lc-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
try MacIcon.makeICNS(from: URL(fileURLWithPath: arguments[1]), to: URL(fileURLWithPath: arguments[2]), scratch: scratch)
