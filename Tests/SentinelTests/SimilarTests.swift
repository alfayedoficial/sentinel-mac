import AppKit
import XCTest
@testable import Sentinel

/// Writes small test pictures so the real perceptual hash can be checked.
enum TestPictures {
    static func image(width: Int, height: Int, pattern: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: width, height: height)
        switch pattern {
        case 0:  // left dark to right light, with a bright square
            NSGradient(starting: .black, ending: .white)?.draw(in: r, angle: 0)
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: CGFloat(width) * 0.15, y: CGFloat(height) * 0.6, width: CGFloat(width) * 0.2, height: CGFloat(height) * 0.25)).fill()
        case 1:  // the opposite: light to dark, dark square elsewhere
            NSGradient(starting: .white, ending: .black)?.draw(in: r, angle: 0)
            NSColor.black.setFill(); NSBezierPath(rect: NSRect(x: CGFloat(width) * 0.65, y: CGFloat(height) * 0.1, width: CGFloat(width) * 0.25, height: CGFloat(height) * 0.3)).fill()
        default: // checkerboard
            for i in 0..<8 { for j in 0..<8 where (i + j) % 2 == 0 {
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: CGFloat(i * width / 8), y: CGFloat(j * height / 8), width: CGFloat(width / 8), height: CGFloat(height / 8))).fill() } }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @discardableResult
    static func write(_ rep: NSBitmapImageRep, to url: URL, jpeg: Bool = false) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])! : rep.representation(using: .png, properties: [:])!
        try? data.write(to: url)
        return url
    }
}

final class PhotoHashTests: XCTestCase {
    func testClusteringByHammingDistance() {
        let a: UInt64 = 0
        let near: UInt64 = 0b111          // 3 bits away from a
        let far: UInt64 = .max            // 64 bits away
        XCTAssertEqual(PhotoHash.distance(a, near), 3)
        XCTAssertEqual(PhotoHash.cluster([a, near, far], maxDistance: 4), [[0, 1]])
        XCTAssertTrue(PhotoHash.cluster([a, near, far], maxDistance: 2).isEmpty)
        XCTAssertEqual(PhotoHash.cluster([a, a, far, far], maxDistance: 0), [[0, 1], [2, 3]], "exact copies only")
        XCTAssertTrue(PhotoHash.cluster([], maxDistance: 8).isEmpty)
        XCTAssertTrue(PhotoHash.cluster([a], maxDistance: 8).isEmpty, "a lone photo is not a group")
    }

    func testChainsJoinIntoOneGroup() {
        // 0 -> 1 -> 2 are each 3 bits apart; 0 and 2 are 6 apart but linked through 1
        let h: [UInt64] = [0, 0b111, 0b111111]
        XCTAssertEqual(PhotoHash.cluster(h, maxDistance: 3), [[0, 1, 2]])
    }

    func testAResizedRecompressedCopyIsClose() throws {
        let sb = Sandbox()
        let original = TestPictures.write(TestPictures.image(width: 600, height: 400, pattern: 0), to: sb.root.appendingPathComponent("a.png"))
        let small = TestPictures.write(TestPictures.image(width: 300, height: 200, pattern: 0), to: sb.root.appendingPathComponent("a-small.jpg"), jpeg: true)
        let a = try XCTUnwrap(PhotoHash.dHash(original)), b = try XCTUnwrap(PhotoHash.dHash(small))
        XCTAssertEqual(a.width, 600); XCTAssertEqual(b.height, 200)
        XCTAssertLessThanOrEqual(PhotoHash.distance(a.hash, b.hash), 6, "same picture, other size and format")
    }

    func testDifferentPicturesAreFar() throws {
        let sb = Sandbox()
        let a = try XCTUnwrap(PhotoHash.dHash(TestPictures.write(TestPictures.image(width: 400, height: 300, pattern: 0), to: sb.root.appendingPathComponent("a.png"))))
        let b = try XCTUnwrap(PhotoHash.dHash(TestPictures.write(TestPictures.image(width: 400, height: 300, pattern: 1), to: sb.root.appendingPathComponent("b.png"))))
        let c = try XCTUnwrap(PhotoHash.dHash(TestPictures.write(TestPictures.image(width: 400, height: 300, pattern: 2), to: sb.root.appendingPathComponent("c.png"))))
        XCTAssertGreaterThan(PhotoHash.distance(a.hash, b.hash), 20)
        XCTAssertGreaterThan(PhotoHash.distance(a.hash, c.hash), 8)
    }

    func testNotAnImageGivesNoHash() {
        let sb = Sandbox()
        XCTAssertNil(PhotoHash.dHash(sb.file("fake.jpg", bytes: 500)))
        XCTAssertNil(PhotoHash.dHash(sb.root.appendingPathComponent("missing.png")))
    }

    func testFinderGroupsOnlyTheSimilarPhotosAndPicksTheBestToKeep() throws {
        let sb = Sandbox()
        TestPictures.write(TestPictures.image(width: 600, height: 400, pattern: 0), to: sb.root.appendingPathComponent("Trip/big.png"))
        TestPictures.write(TestPictures.image(width: 300, height: 200, pattern: 0), to: sb.root.appendingPathComponent("Trip/small.jpg"), jpeg: true)
        TestPictures.write(TestPictures.image(width: 400, height: 300, pattern: 1), to: sb.root.appendingPathComponent("Trip/different.png"))
        sb.file("Trip/notes.txt", bytes: 5000)
        let groups = SimilarPhotoFinder.find(maxDistance: 8, roots: [sb.root], minPixels: 10_000, minBytes: 1000) { _ in }
        XCTAssertEqual(groups.count, 1)
        let g = try XCTUnwrap(groups.first)
        XCTAssertEqual(Set(g.items.map { $0.url.lastPathComponent }), ["big.png", "small.jpg"])
        XCTAssertEqual(g.best.url.lastPathComponent, "big.png", "the sharper, larger picture is kept")
    }

    func testTinyImagesAreIgnored() {
        let sb = Sandbox()
        TestPictures.write(TestPictures.image(width: 64, height: 64, pattern: 0), to: sb.root.appendingPathComponent("icon1.png"))
        TestPictures.write(TestPictures.image(width: 64, height: 64, pattern: 0), to: sb.root.appendingPathComponent("icon2.png"))
        XCTAssertTrue(SimilarPhotoFinder.find(maxDistance: 8, roots: [sb.root], minPixels: 90_000, minBytes: 100) { _ in }.isEmpty, "icons are not photos")
    }

    func testThumbnailsAreSmall() throws {
        let sb = Sandbox()
        let f = TestPictures.write(TestPictures.image(width: 1200, height: 800, pattern: 0), to: sb.root.appendingPathComponent("p.png"))
        let t = try XCTUnwrap(Thumbs.shared.load(f, maxPixel: 200))
        XCTAssertLessThanOrEqual(max(t.size.width, t.size.height), 200)
        XCTAssertNil(Thumbs.shared.load(sb.root.appendingPathComponent("nope.png")))
    }
}

final class SimilarFilesTests: XCTestCase {
    func testFamilyKeys() {
        let expect: [String: String] = [
            "Report.pdf": "report.pdf", "Report (1).pdf": "report.pdf", "report copy.PDF": "report.pdf", "report copy 2.pdf": "report.pdf",
            "Report-2.pdf": "report.pdf", "Report_final_v3.pdf": "report.pdf", "Report - Copy.pdf": "report.pdf", "budget v2.xlsx": "budget.xlsx",
            "notes.txt": "notes.txt", "IMG_2041.jpg": "img_2041.jpg", "2024.pdf": "2024.pdf", "v2.pdf": "v2.pdf", "Photo (12) (1).png": "photo.png",
        ]
        for (name, key) in expect { XCTAssertEqual(FileFamily.key(for: name), key, name) }
    }

    func testDifferentExtensionsAreDifferentFamilies() {
        XCTAssertNotEqual(FileFamily.key(for: "report.pdf"), FileFamily.key(for: "report.docx"))
    }

    func testFinderGroupsVersionsAndLeavesUniqueFilesAlone() throws {
        let sb = Sandbox()
        sb.file("Documents/Report.pdf", bytes: 20_000, age: 1)
        sb.file("Downloads/Report (1).pdf", bytes: 20_000, age: 30)
        sb.file("Desktop/report copy.pdf", bytes: 19_000, age: 90)
        sb.file("Documents/Budget-v2.xlsx", bytes: 20_000, age: 5)
        sb.file("Documents/Budget-v1.xlsx", bytes: 20_000, age: 50)
        sb.file("Documents/unique-file.txt", bytes: 20_000)
        sb.file("Documents/tiny (1).txt", bytes: 10)
        sb.file("Documents/tiny.txt", bytes: 10)
        let groups = SimilarFileFinder.find(roots: [sb.root], minBytes: 1000)
        XCTAssertEqual(Set(groups.map { $0.id }), ["report.pdf", "budget.xlsx"])
        let report = try XCTUnwrap(groups.first { $0.id == "report.pdf" })
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.newest.url.lastPathComponent, "Report.pdf")
    }

    @MainActor
    func testNothingIsPreselectedAndOlderVersionsCanBeSelected() {
        let f = SimilarFileFinder()
        let new = SimilarFile(url: URL(fileURLWithPath: "/tmp/a"), size: 100, modified: Date())
        let old = SimilarFile(url: URL(fileURLWithPath: "/tmp/b"), size: 200, modified: Date(timeIntervalSinceNow: -1000))
        f.groups = [SimilarFileGroup(id: "x.pdf", items: [new, old])]
        XCTAssertTrue(f.remove.isEmpty, "similar is not identical, so the user chooses")
        f.selectOlder()
        XCTAssertEqual(f.remove, [old.id])
        XCTAssertEqual(f.reclaimable, 200)
    }
}
