import XCTest
@testable import Sentinel

final class HistoryTests: XCTestCase {
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    func testRecordsPersistAndReload() {
        let sb = Sandbox()
        let store = sb.root.appendingPathComponent("h/history.json")
        let log = HistoryLog(fileURL: store)
        log.record(kind: "Cache", original: URL(fileURLWithPath: "/tmp/a"), trashed: nil, size: 10)
        log.record(kind: "Duplicate", original: URL(fileURLWithPath: "/tmp/b"), trashed: nil, size: 20)
        pump()
        XCTAssertEqual(log.entries.map { $0.name }, ["b", "a"], "newest first")
        let reloaded = HistoryLog(fileURL: store)
        XCTAssertEqual(reloaded.entries.map { $0.name }, ["b", "a"])
        XCTAssertEqual(reloaded.entries.first?.size, 20)
    }

    func testKeepsOnlyTheLast300() {
        let sb = Sandbox()
        let log = HistoryLog(fileURL: sb.root.appendingPathComponent("h.json"))
        for i in 0..<305 { log.record(kind: "k", original: URL(fileURLWithPath: "/tmp/f\(i)"), trashed: nil, size: 1) }
        pump()
        XCTAssertEqual(log.entries.count, 300)
        XCTAssertEqual(log.entries.first?.name, "f304")
    }

    func testRestoreMovesTheFileBack() throws {
        let sb = Sandbox()
        let original = sb.file("docs/report.txt", bytes: 50)
        let trash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("report.txt")
        try FileManager.default.moveItem(at: original, to: trashed)

        let log = HistoryLog(fileURL: sb.root.appendingPathComponent("h.json"))
        log.record(kind: "Big old file", original: original, trashed: trashed, size: 50)
        pump()
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertNil(log.restore(entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(log.entries.first?.restored, true)
    }

    func testRestoreRefusesWhenItCannotBeDoneSafely() throws {
        let sb = Sandbox()
        let log = HistoryLog(fileURL: sb.root.appendingPathComponent("h.json"))

        // 1. emptied from the Trash
        log.record(kind: "k", original: sb.root.appendingPathComponent("a.txt"), trashed: sb.root.appendingPathComponent("gone.txt"), size: 1)
        // 2. original folder deleted
        let t2 = sb.file("Trash/b.txt")
        log.record(kind: "k", original: sb.root.appendingPathComponent("missing-dir/b.txt"), trashed: t2, size: 1)
        // 3. something already exists at the original path (must never be overwritten)
        let existing = sb.file("c.txt", bytes: 7)
        let t3 = sb.file("Trash/c.txt", bytes: 99)
        log.record(kind: "k", original: existing, trashed: t3, size: 1)
        // 4. recorded without a trash location (Finder fallback)
        log.record(kind: "k", original: sb.root.appendingPathComponent("d.txt"), trashed: nil, size: 1)
        pump()

        for e in log.entries { XCTAssertNotNil(log.restore(e), e.name) }
        XCTAssertEqual(try Data(contentsOf: existing).count, 7, "existing file untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: t3.path))
    }

    func testClearEmptiesTheListAndTheFile() {
        let sb = Sandbox()
        let store = sb.root.appendingPathComponent("h.json")
        let log = HistoryLog(fileURL: store)
        log.record(kind: "k", original: URL(fileURLWithPath: "/tmp/a"), trashed: nil, size: 1)
        pump()
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(HistoryLog(fileURL: store).entries.isEmpty)
    }
}
