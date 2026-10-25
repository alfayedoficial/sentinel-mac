import XCTest
@testable import Sentinel

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(fmtDuration(30), "under a minute")
        XCTAssertEqual(fmtDuration(5 * 60), "5 min")
        XCTAssertEqual(fmtDuration(90 * 60), "1 h 30 min")
        XCTAssertEqual(fmtDuration(49 * 3600), "2 d 1 h")
    }

    func testSizes() {
        XCTAssertTrue(fmtFile(5_000_000).contains("MB"))
        XCTAssertTrue(fmtBytes(2 * 1_073_741_824).contains("GB"))
    }

    func testShellQuoting() {
        XCTAssertEqual(shQuote("plain"), "'plain'")
        XCTAssertEqual(shQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shQuote("a b; rm -rf /"), "'a b; rm -rf /'")
    }
}

final class CleanRangeTests: XCTestCase {
    func testDaysAreInOrder() {
        XCTAssertEqual(CleanRange.allCases.map { $0.days }, [7, 30, 90, 180, 365])
    }

    func testCutoffIsInThePastAndOrdered() {
        let cutoffs = CleanRange.allCases.map { $0.cutoff }
        XCTAssertTrue(cutoffs.allSatisfy { $0 < Date() })
        XCTAssertEqual(cutoffs, cutoffs.sorted(by: >), "longer ranges must reach further back")
    }
}

final class CacheEvaluateTests: XCTestCase {
    private let month = CleanRange.month.cutoff

    func testOldFolderIsReportedWithItsSize() throws {
        let sb = Sandbox()
        sb.file("app/a.bin", bytes: 4096, age: 60)
        sb.file("app/sub/b.bin", bytes: 4096, age: 90)
        sb.age(sb.root.appendingPathComponent("app/sub"), days: 90)
        sb.age(sb.root.appendingPathComponent("app"), days: 60)
        let r = try XCTUnwrap(CacheCleaner.evaluate(sb.root.appendingPathComponent("app"), cutoff: month))
        XCTAssertGreaterThanOrEqual(r.size, 8192)
        XCTAssertLessThan(r.newest, month)
    }

    func testOneRecentFileProtectsTheWholeFolder() {
        let sb = Sandbox()
        sb.file("app/old.bin", age: 200)
        sb.file("app/new.bin", age: 1)
        sb.age(sb.root.appendingPathComponent("app"), days: 200)
        XCTAssertNil(CacheCleaner.evaluate(sb.root.appendingPathComponent("app"), cutoff: month))
    }

    func testRecentFolderIsSkippedEvenIfFilesAreOld() {
        let sb = Sandbox()
        sb.file("app/old.bin", age: 200)   // folder itself keeps today's date
        XCTAssertNil(CacheCleaner.evaluate(sb.root.appendingPathComponent("app"), cutoff: month))
    }

    func testSingleFilesAndTheRangeBoundary() {
        let sb = Sandbox()
        let eightDays = sb.file("eight.log", age: 8)
        let sixDays = sb.file("six.log", age: 6)
        let week = CleanRange.week.cutoff
        XCTAssertNotNil(CacheCleaner.evaluate(eightDays, cutoff: week))
        XCTAssertNil(CacheCleaner.evaluate(sixDays, cutoff: week))
        XCTAssertNil(CacheCleaner.evaluate(eightDays, cutoff: month), "8 days is not old enough for a 1-month range")
    }

    func testMissingPathReturnsNil() {
        XCTAssertNil(CacheCleaner.evaluate(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), cutoff: month))
    }

    func testScanRootsIncludeCachesAndLogs() {
        let paths = CacheCleaner.roots().map { $0.url.path }
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Caches") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Logs") })
    }
}

@MainActor
final class CacheCleanerStateTests: XCTestCase {
    func testTotalsAndGrouping() {
        let c = CacheCleaner()
        let u = URL(fileURLWithPath: "/tmp/x")
        c.items = [
            CacheItem(url: u.appendingPathComponent("a"), name: "a", category: "App caches", size: 300, lastModified: .distantPast, inUse: false, isSystem: false),
            CacheItem(url: u.appendingPathComponent("b"), name: "b", category: "Logs", size: 100, lastModified: .distantPast, inUse: false, isSystem: false),
            CacheItem(url: u.appendingPathComponent("c"), name: "c", category: "App caches", size: 50, lastModified: .distantPast, inUse: true, isSystem: false),
        ]
        c.setAll(true)
        XCTAssertEqual(c.selected.count, 2, "items whose app is running are never auto-selected")
        XCTAssertEqual(c.selectedBytes, 400)
        XCTAssertEqual(c.totalBytes, 450)
        XCTAssertEqual(c.grouped.first?.0, "App caches", "biggest category first")
        c.toggle(c.items[0])
        XCTAssertEqual(c.selectedBytes, 100)
        c.setAll(false)
        XCTAssertTrue(c.selected.isEmpty)
    }

    func testPermanentCleanDeletesOnlySelectedItems() async throws {
        let sb = Sandbox()
        let doomed = sb.file("cache/doomed.bin", bytes: 2048)
        let kept = sb.file("cache/kept.bin", bytes: 2048)
        let c = CacheCleaner()
        let a = CacheItem(url: doomed, name: "doomed", category: "App caches", size: 2048, lastModified: .distantPast, inUse: false, isSystem: false)
        let b = CacheItem(url: kept, name: "kept", category: "App caches", size: 2048, lastModified: .distantPast, inUse: false, isSystem: false)
        c.items = [a, b]
        c.selected = [a.id]
        c.permanent = true
        c.clean()
        for _ in 0..<100 { if case .done = c.state { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .done(let freed, let failed) = c.state else { return XCTFail("clean did not finish") }
        XCTAssertEqual(freed, 2048)
        XCTAssertEqual(failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(c.items.map { $0.name }, ["kept"])
    }
}
