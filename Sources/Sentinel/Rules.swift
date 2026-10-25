import Foundation

/// When does an app look "unused"? Pure logic, so it can be tested without a running Mac.
struct FlagRules {
    var idleMinutes: Double = 20
    var memoryThreshold: UInt64 = 300 * 1_048_576
    var cpuThreshold: Double = 15

    static func current() -> FlagRules {
        let d = UserDefaults.standard
        return FlagRules(
            idleMinutes: (d.object(forKey: "idleMinutes") as? Double) ?? 20,
            memoryThreshold: UInt64(((d.object(forKey: "memThresholdMB") as? Double) ?? 300) * 1_048_576),
            cpuThreshold: (d.object(forKey: "cpuThreshold") as? Double) ?? 15)
    }

    /// Empty when the app should be left alone.
    func reasons(for u: AppUsage, memoryPressure: Int, battery: BatteryInfo) -> [String] {
        if u.isFrontmost || u.awake { return [] }
        var reasons: [String] = []
        if !u.hasWindow && u.idle >= idleMinutes * 60 && u.footprint >= memoryThreshold {
            reasons.append("No visible window and unused for \(fmtDuration(u.idle)), yet it still holds \(fmtBytes(u.footprint)) of memory.")
        }
        if u.cpuAvg >= cpuThreshold && (!u.hasWindow || u.idle >= 300) {
            let extra = battery.hasBattery && !battery.onAC ? " This drains your battery faster." : ""
            reasons.append("Using \(Int(u.cpuAvg))% CPU in the background while you are not using it.\(extra)")
        }
        if battery.hasBattery && !battery.onAC && u.energyMW >= 800 && u.idle >= 300 {
            reasons.append("High energy use (about \(String(format: "%.1f", u.energyMW / 1000)) W) while on battery.")
        }
        if memoryPressure >= 2 && !u.hasWindow && u.idle >= 300 && u.footprint >= 150 * 1_048_576 && reasons.isEmpty {
            reasons.append("Your Mac is short on memory and this app is idle with \(fmtBytes(u.footprint)) in use.")
        }
        return reasons
    }
}
