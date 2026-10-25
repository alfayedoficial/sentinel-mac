import XCTest
@testable import Sentinel

final class FlagRulesTests: XCTestCase {
    private let ac = BatteryInfo(hasBattery: true, percent: 80, charging: false, onAC: true, minutesRemaining: nil)
    private let onBattery = BatteryInfo(hasBattery: true, percent: 80, charging: false, onAC: false, minutesRemaining: 200)
    private let rules = FlagRules()

    private func reasons(_ u: AppUsage, pressure: Int = 1, battery: BatteryInfo? = nil) -> [String] {
        rules.reasons(for: u, memoryPressure: pressure, battery: battery ?? ac)
    }

    func testIdleHeavyAppWithoutWindowIsFlagged() {
        let r = reasons(usage(footprintMB: 500, idleMin: 30))
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].contains("No visible window"))
    }

    func testNotIdleLongEnoughOrNotHeavyEnoughIsLeftAlone() {
        XCTAssertTrue(reasons(usage(footprintMB: 500, idleMin: 10)).isEmpty)
        XCTAssertTrue(reasons(usage(footprintMB: 100, idleMin: 120)).isEmpty)
    }

    func testAppWithAVisibleWindowIsNotFlaggedForMemory() {
        XCTAssertTrue(reasons(usage(footprintMB: 2000, idleMin: 600, window: true)).isEmpty)
    }

    func testFrontmostAndKeepAwakeAppsAreNeverFlagged() {
        XCTAssertTrue(reasons(usage(footprintMB: 4000, cpuAvg: 90, idleMin: 600, front: true)).isEmpty)
        XCTAssertTrue(reasons(usage(footprintMB: 4000, cpuAvg: 90, idleMin: 600, awake: true)).isEmpty, "playing audio / downloading")
    }

    func testBackgroundCPUIsFlaggedOnlyWhenNotInUse() {
        XCTAssertTrue(reasons(usage(footprintMB: 50, cpuAvg: 40, idleMin: 1, window: false)).contains { $0.contains("CPU") })
        XCTAssertTrue(reasons(usage(footprintMB: 50, cpuAvg: 40, idleMin: 1, window: true)).isEmpty, "window open and recently used")
        XCTAssertTrue(reasons(usage(footprintMB: 50, cpuAvg: 40, idleMin: 10, window: true)).contains { $0.contains("CPU") })
        XCTAssertTrue(reasons(usage(footprintMB: 50, cpuAvg: 5, idleMin: 10)).isEmpty, "below the CPU threshold")
    }

    func testBatteryMentionedOnlyOffCharger() {
        let u = usage(footprintMB: 50, cpuAvg: 40, idleMin: 10)
        XCTAssertTrue(reasons(u, battery: onBattery)[0].contains("battery"))
        XCTAssertFalse(reasons(u, battery: ac)[0].contains("battery"))
    }

    func testEnergyRuleNeedsBatteryAndIdle() {
        let u = usage(footprintMB: 50, idleMin: 6, energyMW: 1500)
        XCTAssertTrue(reasons(u, battery: onBattery).contains { $0.contains("energy") })
        XCTAssertTrue(reasons(u, battery: ac).isEmpty)
        XCTAssertTrue(reasons(usage(footprintMB: 50, idleMin: 1, energyMW: 1500), battery: onBattery).isEmpty)
    }

    func testMemoryPressureLowersTheBar() {
        let u = usage(footprintMB: 200, idleMin: 6)
        XCTAssertTrue(reasons(u, pressure: 1).isEmpty)
        XCTAssertTrue(reasons(u, pressure: 2).contains { $0.contains("short on memory") })
        XCTAssertTrue(reasons(usage(footprintMB: 100, idleMin: 6), pressure: 4).isEmpty, "too small to bother")
    }

    func testThresholdsAreConfigurable() {
        var strict = FlagRules()
        strict.idleMinutes = 5
        strict.memoryThreshold = 100 * 1_048_576
        XCTAssertFalse(strict.reasons(for: usage(footprintMB: 150, idleMin: 6), memoryPressure: 1, battery: ac).isEmpty)
        var lax = FlagRules()
        lax.memoryThreshold = 1024 * 1_048_576
        XCTAssertTrue(lax.reasons(for: usage(footprintMB: 500, idleMin: 600), memoryPressure: 1, battery: ac).isEmpty)
    }
}

final class SamplerTests: XCTestCase {
    func testReadsSaneSystemNumbers() {
        let sampler = Sampler()
        for _ in 0..<2 {
            let s = sampler.sample(wanted: [])
            XCTAssertGreaterThan(s.memory.total, 0)
            XCTAssertTrue((0.0...1.0).contains(s.memory.fraction))
            XCTAssertTrue((1...4).contains(s.memory.pressure))
            XCTAssertTrue((0...100).contains(s.battery.percent))
            XCTAssertTrue(s.groups.isEmpty)
        }
    }

    func testMeasuresARunningApp() throws {
        let finder = "/System/Library/CoreServices/Finder.app"
        let s = Sampler()
        _ = s.sample(wanted: [finder])
        Thread.sleep(forTimeInterval: 0.3)
        let second = s.sample(wanted: [finder])
        guard let g = second.groups[finder] else { throw XCTSkip("Finder is not running (headless session)") }
        XCTAssertGreaterThan(g.footprint, 1_000_000)
        XCTAssertFalse(g.pids.isEmpty)
        XCTAssertGreaterThanOrEqual(g.cpu, 0)
    }
}

final class StartupNameTests: XCTestCase {
    func testPrettyNames() {
        XCTAssertEqual(StartupManager.prettyName("com.adobe.ARMDC.Communicator", nil), "adobe ARMDC Communicator")
        XCTAssertEqual(StartupManager.prettyName("com.foo.bar", "/Applications/Foo.app/Contents/MacOS/foo"), "Foo")
        XCTAssertEqual(StartupManager.prettyName("simple", nil), "simple")
    }

    func testRunningLabelsReadsLaunchctl() {
        XCTAssertFalse(StartupManager.runningLabels().isEmpty)
    }

    func testToolKindsAreComplete() {
        let kinds = ToolKind.allCases
        XCTAssertEqual(Set(kinds.map { $0.id }).count, kinds.count)
        for k in kinds {
            XCTAssertFalse(k.title.isEmpty); XCTAssertFalse(k.blurb.isEmpty); XCTAssertFalse(k.icon.isEmpty)
        }
        XCTAssertTrue(kinds.contains(.maintenance) && kinds.contains(.history))
    }
}
