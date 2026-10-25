import XCTest
@testable import Sentinel

final class UpdateLogicTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateLogic.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateLogic.isNewer("v1.10.0", than: "1.9.9"), "numbers, not text: 10 > 9")
        XCTAssertTrue(UpdateLogic.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(UpdateLogic.isNewer("1.1", than: "1.1.0"), "1.1 equals 1.1.0")
        XCTAssertFalse(UpdateLogic.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateLogic.isNewer("1.0.9", than: "1.1.0"), "never downgrade")
        XCTAssertFalse(UpdateLogic.isNewer("garbage", than: "1.0.0"))
    }

    func testOnlyGitHubDownloadsOverHTTPSAreTrusted() {
        for ok in ["https://github.com/a/b/releases/download/v1/Sentinel.zip", "https://objects.githubusercontent.com/x", "https://release-assets.githubusercontent.com/y"] {
            XCTAssertTrue(UpdateLogic.isTrustedDownload(URL(string: ok)!), ok)
        }
        for bad in ["http://github.com/a.zip", "https://evil.example.com/Sentinel.zip", "https://github.com.evil.com/a.zip",
                    "https://notgithub.com/a.zip", "ftp://github.com/a.zip", "file:///tmp/a.zip"] {
            XCTAssertFalse(UpdateLogic.isTrustedDownload(URL(string: bad)!), bad)
        }
    }

    private func releaseJSON(tag: String = "v1.2.0", draft: Bool = false, pre: Bool = false, zip: String = "https://github.com/x/y/releases/download/v1.2.0/Sentinel.zip",
                             sum: String? = "https://github.com/x/y/releases/download/v1.2.0/Sentinel.zip.sha256", includeZip: Bool = true) -> Data {
        var assets: [String] = []
        if includeZip { assets.append("{\"name\":\"Sentinel.zip\",\"browser_download_url\":\"\(zip)\"}") }
        if let sum { assets.append("{\"name\":\"Sentinel.zip.sha256\",\"browser_download_url\":\"\(sum)\"}") }
        return Data("{\"tag_name\":\"\(tag)\",\"body\":\"notes\",\"html_url\":\"https://github.com/x/y/releases/tag/\(tag)\",\"draft\":\(draft),\"prerelease\":\(pre),\"assets\":[\(assets.joined(separator: ","))]}".utf8)
    }

    func testParsesARelease() throws {
        let r = try UpdateLogic.parseRelease(releaseJSON())
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.tag, "v1.2.0")
        XCTAssertEqual(r.notes, "notes")
        XCTAssertNotNil(r.checksumURL)
        XCTAssertEqual(r.zipURL.lastPathComponent, "Sentinel.zip")
    }

    func testRefusesUnusableReleases() {
        XCTAssertThrowsError(try UpdateLogic.parseRelease(releaseJSON(draft: true)))
        XCTAssertThrowsError(try UpdateLogic.parseRelease(releaseJSON(pre: true)))
        XCTAssertThrowsError(try UpdateLogic.parseRelease(releaseJSON(includeZip: false)))
        XCTAssertThrowsError(try UpdateLogic.parseRelease(releaseJSON(zip: "https://evil.example.com/Sentinel.zip")), "download from another host")
        XCTAssertThrowsError(try UpdateLogic.parseRelease(releaseJSON(sum: "https://evil.example.com/Sentinel.zip.sha256")))
        XCTAssertThrowsError(try UpdateLogic.parseRelease(Data("not json".utf8)))
        XCTAssertThrowsError(try UpdateLogic.parseRelease(Data("{}".utf8)))
    }

    func testChecksumParsing() {
        let h = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateLogic.parseChecksum("\(h)  Sentinel.zip\n"), h)
        XCTAssertEqual(UpdateLogic.parseChecksum(h.uppercased()), h)
        XCTAssertNil(UpdateLogic.parseChecksum(""))
        XCTAssertNil(UpdateLogic.parseChecksum("zz\(h.dropFirst(2))  x"), "not hex")
        XCTAssertNil(UpdateLogic.parseChecksum("abc123  Sentinel.zip"), "too short")
    }

    func testSHA256OfAFile() throws {
        let sb = Sandbox()
        let f = sb.root.appendingPathComponent("abc.txt")
        try "abc".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try UpdateLogic.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class BundleValidationTests: XCTestCase {
    /// Builds a tiny fake app bundle. `sign` signs it ad hoc with the given identifier.
    private func makeApp(in sb: Sandbox, name: String = "Sentinel.app", id: String = "com.afapps.sentinel", version: String = "9.9.9", sign: String? = "com.afapps.sentinel") throws -> URL {
        let app = sb.root.appendingPathComponent(name)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: macos.appendingPathComponent("Sentinel").path)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Sentinel", "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let sign {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", "--identifier", sign, app.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        return app
    }

    func testAcceptsAValidNewerSentinel() throws {
        let sb = Sandbox()
        let app = try makeApp(in: sb)
        XCTAssertEqual(try UpdateLogic.validateBundle(app, newerThan: "1.0.0"), "9.9.9")
    }

    func testRefusesAnOlderOrEqualVersion() throws {
        let sb = Sandbox()
        let app = try makeApp(in: sb, version: "1.0.0")
        XCTAssertThrowsError(try UpdateLogic.validateBundle(app, newerThan: "1.0.0")) { XCTAssertTrue("\($0)".contains("not newer"), "\($0)") }
        XCTAssertThrowsError(try UpdateLogic.validateBundle(app, newerThan: "2.0.0")) { XCTAssertTrue("\($0)".contains("not newer"), "\($0)") }
        XCTAssertNoThrow(try UpdateLogic.validateBundle(app, newerThan: "0.9.0"))
    }

    func testRefusesAnotherApp() throws {
        let sb = Sandbox()
        let app = try makeApp(in: sb, id: "com.evil.other", sign: "com.evil.other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertThrowsError(try UpdateLogic.validateBundle(app, newerThan: "1.0.0")) { XCTAssertTrue("\($0)".contains("not Sentinel")) }
    }

    func testRefusesAWrongSigningIdentity() throws {
        // right bundle id in Info.plist, but signed as something else
        let sb = Sandbox()
        let app = try makeApp(in: sb, sign: "com.evil.signer")
        XCTAssertThrowsError(try UpdateLogic.validateBundle(app, newerThan: "1.0.0")) { XCTAssertTrue("\($0)".contains("identity")) }
    }

    func testRefusesAnUnsignedOrTamperedApp() throws {
        let sb = Sandbox()
        let unsigned = try makeApp(in: sb, name: "Unsigned.app", sign: nil)
        XCTAssertThrowsError(try UpdateLogic.validateBundle(unsigned, newerThan: "1.0.0")) { XCTAssertTrue("\($0)".contains("signature"), "\($0)") }
        let tampered = try makeApp(in: sb, name: "Tampered.app")
        XCTAssertNoThrow(try UpdateLogic.validateBundle(tampered, newerThan: "1.0.0"), "valid before it is changed")
        try Data("changed after signing".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/Sentinel"))
        XCTAssertThrowsError(try UpdateLogic.validateBundle(tampered, newerThan: "1.0.0")) { XCTAssertTrue("\($0)".contains("signature"), "\($0)") }
    }

    func testSwapReplacesAndKeepsABackup() throws {
        let sb = Sandbox()
        let old = sb.root.appendingPathComponent("Apps/Sentinel.app")
        let new = sb.root.appendingPathComponent("Fresh/Sentinel.app")
        for (u, text) in [(old, "old"), (new, "new")] {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try text.write(to: u.appendingPathComponent("v.txt"), atomically: true, encoding: .utf8)
        }
        let backup = sb.root.appendingPathComponent("previous")
        try UpdateLogic.swap(new: new, over: old, backupDir: backup)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("v.txt")), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("Sentinel.app/v.txt")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    func testFailedSwapRestoresTheOldApp() throws {
        let sb = Sandbox()
        let old = sb.root.appendingPathComponent("Sentinel.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("v.txt"), atomically: true, encoding: .utf8)
        let missing = sb.root.appendingPathComponent("does-not-exist/Sentinel.app")
        XCTAssertThrowsError(try UpdateLogic.swap(new: missing, over: old, backupDir: sb.root.appendingPathComponent("previous")))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("v.txt")), "old", "the working app must survive a failed update")
    }
}

@MainActor
final class UpdaterStateTests: XCTestCase {
    private func json(_ tag: String) -> Data {
        Data("{\"tag_name\":\"\(tag)\",\"body\":\"n\",\"html_url\":\"https://github.com/x/y/releases/tag/\(tag)\",\"assets\":[{\"name\":\"Sentinel.zip\",\"browser_download_url\":\"https://github.com/x/y/releases/download/\(tag)/Sentinel.zip\"},{\"name\":\"Sentinel.zip.sha256\",\"browser_download_url\":\"https://github.com/x/y/releases/download/\(tag)/Sentinel.zip.sha256\"}]}".utf8)
    }

    func testNewerReleaseBecomesAvailable() async {
        let u = Updater(); u.currentVersion = "1.0.0"
        u.fetch = { _ in self.json("v1.1.0") }
        await u.check()
        guard case .available(let info) = u.state else { return XCTFail("expected an update, got \(u.state)") }
        XCTAssertEqual(info.version, "1.1.0")
        XCTAssertNotNil(u.lastChecked)
    }

    func testSameOrOlderReleaseMeansUpToDate() async {
        let u = Updater(); u.currentVersion = "1.1.0"
        u.fetch = { _ in self.json("v1.1.0") }
        await u.check()
        XCTAssertEqual(u.state, .upToDate)
        u.fetch = { _ in self.json("v1.0.0") }
        await u.check()
        XCTAssertEqual(u.state, .upToDate)
    }

    func testOfflineIsAQuietFailureNotACrash() async {
        let u = Updater(); u.currentVersion = "1.0.0"
        u.fetch = { _ in throw UpdateError.network("offline") }
        await u.check()
        guard case .failed(let m) = u.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(m.contains("offline"))
    }

    func testTheRequestIdentifiesTheAppAndSendsNothingElse() async {
        let u = Updater(); u.currentVersion = "1.0.0"
        var seen: URLRequest?
        u.fetch = { req in seen = req; return self.json("v1.0.0") }
        await u.check()
        XCTAssertEqual(seen?.url, UpdateLogic.latestReleaseAPI)
        XCTAssertEqual(seen?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "User-Agent"), "Sentinel/1.0.0")
        XCTAssertNil(seen?.httpBody)
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Cookie"))
    }

    /// Talks to GitHub for real. Run with SENTINEL_NETWORK_TESTS=1 swift test --filter testRealLatestRelease
    func testRealLatestRelease() async throws {
        guard ProcessInfo.processInfo.environment["SENTINEL_NETWORK_TESTS"] == "1" else { throw XCTSkip("set SENTINEL_NETWORK_TESTS=1 to run") }
        let u = Updater(); u.currentVersion = "0.0.1"
        await u.check()
        guard case .available(let info) = u.state else { return XCTFail("expected the real latest release, got \(u.state)") }
        XCTAssertTrue(UpdateLogic.isTrustedDownload(info.zipURL))
        XCTAssertNotNil(info.checksumURL, "every release must publish a checksum")
        let sum = String(data: try await u.fetch(URLRequest(url: info.checksumURL!)), encoding: .utf8) ?? ""
        XCTAssertNotNil(UpdateLogic.parseChecksum(sum))
    }
}
