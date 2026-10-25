import AppKit
import XCTest
@testable import Sentinel

/// A throw-away folder that is deleted when the test ends.
final class Sandbox {
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SentinelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, bytes: Int = 1024, fill: UInt8 = 0x41, age days: Double = 0) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: fill, count: bytes))
        age(url, days: days)
        return url
    }

    func age(_ url: URL, days: Double) {
        guard days > 0 else { return }
        let d = Date().addingTimeInterval(-days * 86400)
        try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: url.path)
    }
}

func usage(footprintMB: UInt64 = 500, cpuAvg: Double = 0, idleMin: Double = 30, window: Bool = false,
           front: Bool = false, awake: Bool = false, energyMW: Double = 0) -> AppUsage {
    AppUsage(id: "/Applications/Test.app", name: "Test", bundleID: "com.test.app",
             footprint: footprintMB * 1_048_576, cpu: cpuAvg, cpuAvg: cpuAvg, energyMW: energyMW,
             isFrontmost: front, hasWindow: window, awake: awake, idle: idleMin * 60, icon: NSImage())
}
