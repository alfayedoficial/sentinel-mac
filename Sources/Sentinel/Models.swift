import AppKit
import SwiftUI

func fmtBytes(_ v: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
}

func fmtFile(_ v: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
}

func fmtDuration(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    if m < 1 { return "under a minute" }
    if m < 60 { return "\(m) min" }
    let h = m / 60
    if h < 24 { return "\(h) h \(m % 60) min" }
    return "\(h / 24) d \(h % 24) h"
}

struct MemoryInfo: Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var pressure: Int = 1

    var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    var percent: Int { Int((fraction * 100).rounded()) }
    var pressureLabel: String { pressure >= 4 ? "Critical" : pressure >= 2 ? "Warning" : "Normal" }
    var pressureColor: Color { pressure >= 4 ? Theme.danger : pressure >= 2 ? Theme.warning : Theme.success }
}

struct BatteryInfo: Equatable {
    var hasBattery = false
    var percent = 0
    var charging = false
    var onAC = true
    var minutesRemaining: Int?

    var fraction: Double { Double(percent) / 100 }
    var color: Color { percent <= 20 && !onAC ? Theme.danger : percent <= 40 && !onAC ? Theme.warning : Theme.success }
    var statusLabel: String {
        if !hasBattery { return "No battery" }
        if charging { return "Charging" }
        if onAC { return "Plugged in" }
        if let m = minutesRemaining, m > 0 { return "\(m / 60) h \(m % 60) min left" }
        return "On battery"
    }
}

struct AppUsage: Identifiable {
    let id: String            // bundle path
    let name: String
    let bundleID: String
    let footprint: UInt64
    let cpu: Double
    let cpuAvg: Double
    let energyMW: Double
    let isFrontmost: Bool
    let hasWindow: Bool
    let awake: Bool
    let idle: TimeInterval
    let icon: NSImage
}

struct FlaggedApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let icon: NSImage
    let footprint: UInt64
    let cpu: Double
    let idle: TimeInterval
    let reasons: [String]
}

extension Color {
    static let brandA = Theme.accent
    static let brandB = Theme.violet
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [.brandA, .brandB], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
