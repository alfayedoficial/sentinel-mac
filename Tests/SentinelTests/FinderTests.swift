import XCTest
@testable import Sentinel

final class DuplicateFinderTests: XCTestCase {
    private let mb = 1_048_576

    func testFindsIdenticalFilesAcrossFolders() throws {
        let sb = Sandbox()
        let a = sb.file("one/a.bin", bytes: 2 * mb, fill: 0x11)
        let b = sb.file("two/deep/b.bin", bytes: 2 * mb, fill: 0x11)
        sb.file("two/c.bin", bytes: 2 * mb, fill: 0x22)          // same size, different content
        sb.file("two/tiny.bin", bytes: 100, fill: 0x11)           // identical content but below the minimum
        let groups = DuplicateFinder.find(minBytes: Int64(mb), roots: [sb.root]) { _ in }
        XCTAssertEqual(groups.count, 1)
        let paths = Set(try XCTUnwrap(groups.first).files.map { $0.url.standardizedFileURL.path })
        XCTAssertEqual(paths, [a.standardizedFileURL.path, b.standardizedFileURL.path])
    }

    func testSameSizeFilesThatDifferOnlyInTheMiddleAreNotDuplicates() {
        let sb = Sandbox()
        let size = 1_000_000
        let a = sb.file("a.bin", bytes: size, fill: 0x33)
        let b = sb.file("b.bin", bytes: size, fill: 0x33)
        var data = try! Data(contentsOf: b)
        data[size / 2] = 0x99                                      // quick hash only sees head and tail
        try! data.write(to: b)
        XCTAssertEqual(DuplicateFinder.quickHash(a, size: Int64(size)), DuplicateFinder.quickHash(b, size: Int64(size)))
        XCTAssertNotEqual(DuplicateFinder.fullHash(a), DuplicateFinder.fullHash(b))
        XCTAssertTrue(DuplicateFinder.find(minBytes: 1000, roots: [sb.root]) { _ in }.isEmpty)
    }

    func testSymlinksAndNodeModulesAreIgnored() throws {
        let sb = Sandbox()
        let real = sb.file("real.bin", bytes: 2 * mb, fill: 0x44)
        try FileManager.default.createSymbolicLink(at: sb.root.appendingPathComponent("link.bin"), withDestinationURL: real)
        sb.file("node_modules/pkg/copy.bin", bytes: 2 * mb, fill: 0x44)
        XCTAssertTrue(DuplicateFinder.find(minBytes: Int64(mb), roots: [sb.root]) { _ in }.isEmpty)
    }

    func testThreeCopiesFormOneGroup() throws {
        let sb = Sandbox()
        for n in ["x", "y", "z"] { sb.file("\(n)/f.bin", bytes: 300_000, fill: 0x55) }
        let groups = DuplicateFinder.find(minBytes: 1000, roots: [sb.root]) { _ in }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, 3)
    }

    func testHashesAreStableAndContentBased() {
        let sb = Sandbox()
        let a = sb.file("a", bytes: 5000, fill: 0x01)
        let b = sb.file("b", bytes: 5000, fill: 0x01)
        let c = sb.file("c", bytes: 5000, fill: 0x02)
        XCTAssertEqual(DuplicateFinder.fullHash(a), DuplicateFinder.fullHash(b))
        XCTAssertNotEqual(DuplicateFinder.fullHash(a), DuplicateFinder.fullHash(c))
        XCTAssertNil(DuplicateFinder.fullHash(sb.root.appendingPathComponent("missing")))
    }

    @MainActor
    func testKeepMarksEveryOtherCopyForRemoval() {
        let finder = DuplicateFinder()
        let files = (0..<3).map { DupFile(url: URL(fileURLWithPath: "/tmp/f\($0)"), size: 1000, modified: Date(timeIntervalSince1970: Double($0))) }
        let g = DupGroup(id: "h", files: files)
        finder.groups = [g]
        finder.keep(files[1], in: g)
        XCTAssertEqual(finder.remove, [files[0].id, files[2].id])
        XCTAssertEqual(finder.reclaimable, 2000)
        finder.toggle(files[0])
        XCTAssertEqual(finder.reclaimable, 1000)
    }
}

final class BigFileSearchTests: XCTestCase {
    func testFindsOnlyBigAndOldFilesLargestFirst() {
        let sb = Sandbox()
        sb.file("Movies/big-old.mov", bytes: 3_000_000, age: 120)
        sb.file("Movies/bigger-old.mov", bytes: 5_000_000, age: 200)
        sb.file("Movies/big-new.mov", bytes: 3_000_000, age: 2)
        sb.file("Movies/small-old.txt", bytes: 100_000, age: 400)
        let found = BigFileFinder.search(minBytes: 2_000_000, cutoff: CleanRange.threeMonths.cutoff, roots: [sb.root])
        XCTAssertEqual(found.map { $0.url.lastPathComponent }, ["bigger-old.mov", "big-old.mov"])
        XCTAssertGreaterThan(found[0].size, found[1].size)
    }

    func testNodeModulesIsSkipped() {
        let sb = Sandbox()
        sb.file("node_modules/x/huge.bin", bytes: 3_000_000, age: 300)
        XCTAssertTrue(BigFileFinder.search(minBytes: 1_000_000, cutoff: Date(), roots: [sb.root]).isEmpty)
    }
}

final class LeftoverTests: XCTestCase {
    func testFindsOnlyDataBelongingToTheApp() {
        let sb = Sandbox()
        sb.file("Caches/com.foo.Bar/c.bin")
        sb.file("Preferences/com.foo.Bar.plist")
        sb.file("Application Support/Bar/data.db")
        sb.file("Containers/com.foo.Bar/Data/x")
        sb.file("Saved Application State/com.foo.Bar.savedState/w.data")
        sb.file("Caches/com.foo.Bar.helper/h.bin")
        // must NOT match
        sb.file("Caches/com.other.Thing/c.bin")
        sb.file("Caches/com.foo.BarBaz/c.bin")
        sb.file("Application Support/Barbecue/x")
        sb.file("Preferences/com.foo.Baz.plist")
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Bar.app"), name: "Bar", bundleID: "com.foo.Bar", size: 0)
        let found = Set(Uninstaller.findLeftovers(for: app, library: sb.root).map { $0.url.lastPathComponent })
        XCTAssertEqual(found, ["com.foo.Bar", "com.foo.Bar.plist", "Bar", "com.foo.Bar.savedState", "com.foo.Bar.helper"])
    }

    func testAppWithoutDotInBundleIDDoesNotMatchEverything() {
        let sb = Sandbox()
        sb.file("Caches/anything/x")
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Odd.app"), name: "Odd", bundleID: "Odd.app", size: 0)
        XCTAssertTrue(Uninstaller.findLeftovers(for: app, library: sb.root).isEmpty)
    }

    func testDiscoverListsRealAppsAndSkipsSentinel() {
        let apps = Uninstaller.discover()
        XCTAssertFalse(apps.isEmpty)
        XCTAssertTrue(apps.allSatisfy { $0.url.pathExtension == "app" })
        XCTAssertFalse(apps.contains { $0.bundleID == "com.afapps.sentinel" })
        XCTAssertEqual(apps.map { $0.name.lowercased() }, apps.map { $0.name.lowercased() }.sorted())
    }
}
