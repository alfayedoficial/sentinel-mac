import AppKit
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

// MARK: - Small shared helpers

/// Icons are looked up once and reused, so SwiftUI bodies never hit the file system.
final class IconCache: @unchecked Sendable {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

/// The menu-bar label only needs these two values, so it observes this instead of the whole monitor.
@MainActor
final class BarState: ObservableObject {
    @Published var percent = 0
    @Published var alert = false
    @Published var threat = false
}

// MARK: - Background sampler (never touches the main thread)

struct RunInfo {
    let path: String
    let bundleID: String
    let name: String
    let launch: Date?
}

struct GroupSample {
    var footprint: UInt64
    var cpu: Double
    var cpuAvg: Double
    var energyMW: Double
    var pids: [Int32]
    var hasWindow: Bool
    var awake: Bool
}

struct Sample {
    var memory: MemoryInfo
    var battery: BatteryInfo
    var groups: [String: GroupSample]
}

final class Sampler: @unchecked Sendable {
    private struct Snap { var path: String; var footprint: UInt64; var cpuNs: UInt64; var energy: UInt64 }

    private var prev: [Int32: (cpu: UInt64, energy: UInt64)] = [:]
    private var prevTime: UInt64 = 0
    private var cpuHistory: [String: [Double]] = [:]
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    func sample(wanted: Set<String>) -> Sample {
        let memory = readMemory()
        let battery = readBattery()
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let dt = prevTime == 0 ? 0 : Double(nowNs - prevTime)
        let snaps = sampleProcesses()

        var acc: [String: (foot: UInt64, cpu: UInt64, energy: UInt64, pids: [Int32])] = [:]
        var newPrev: [Int32: (cpu: UInt64, energy: UInt64)] = [:]
        for (pid, s) in snaps {
            newPrev[pid] = (s.cpuNs, s.energy)
            guard wanted.contains(s.path) else { continue }
            var g = acc[s.path] ?? (0, 0, 0, [])
            g.foot += s.footprint
            if let p = prev[pid] {
                if s.cpuNs >= p.cpu { g.cpu += s.cpuNs - p.cpu }
                if s.energy >= p.energy { g.energy += s.energy - p.energy }
            }
            g.pids.append(pid)
            acc[s.path] = g
        }
        prev = newPrev
        prevTime = nowNs

        let windows = pidsWithWindows()
        let awake = pidsKeepingAwake()
        var groups: [String: GroupSample] = [:]
        for (path, g) in acc {
            let cpu = dt > 0 ? Double(g.cpu) / dt * 100 : 0
            var hist = cpuHistory[path] ?? []
            hist.append(cpu)
            if hist.count > 6 { hist.removeFirst(hist.count - 6) }
            cpuHistory[path] = hist
            groups[path] = GroupSample(
                footprint: g.foot, cpu: cpu, cpuAvg: hist.reduce(0, +) / Double(hist.count),
                energyMW: dt > 0 ? Double(g.energy) / dt * 1000 : 0, pids: g.pids,
                hasWindow: g.pids.contains(where: { windows.contains($0) }),
                awake: g.pids.contains(where: { awake.contains($0) }))
        }
        cpuHistory = cpuHistory.filter { wanted.contains($0.key) }
        return Sample(memory: memory, battery: battery, groups: groups)
    }

    private func readMemory() -> MemoryInfo {
        var info = MemoryInfo()
        info.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            let appPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            info.wired = UInt64(stats.wire_count) * page
            info.compressed = UInt64(stats.compressor_page_count) * page
            info.used = appPages * page + info.wired + info.compressed
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { info.pressure = Int(level) }
        return info
    }

    private func readBattery() -> BatteryInfo {
        var b = BatteryInfo()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return b }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery" else { continue }
            b.hasBattery = true
            let cur = desc["Current Capacity"] as? Int ?? 0
            let max = desc["Max Capacity"] as? Int ?? 100
            b.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            b.charging = desc["Is Charging"] as? Bool ?? false
            b.onAC = (desc["Power Source State"] as? String) == "AC Power"
            if let t = desc["Time to Empty"] as? Int, t > 0 { b.minutesRemaining = t }
        }
        return b
    }

    private func sampleProcesses() -> [Int32: Snap] {
        var out: [Int32: Snap] = [:]
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return out }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, 4096)
            guard len > 0 else { continue }
            let path = String(cString: buf)
            guard let r = path.range(of: ".app/") else { continue }
            let root = String(path[..<r.upperBound].dropLast())

            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let ticks = ru.ri_user_time &+ ru.ri_system_time
            let cpuNs = ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            out[pid] = Snap(path: root, footprint: ru.ri_phys_footprint, cpuNs: cpuNs, energy: ru.ri_billed_energy)
        }
        return out
    }

    private func pidsWithWindows() -> Set<Int32> {
        var set: Set<Int32> = []
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return set }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let width = (b["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
            if width * height > 400 { set.insert(pid) }
        }
        return set
    }

    /// Processes holding a "keep awake" assertion (audio, downloads, calls) are never flagged.
    private func pidsKeepingAwake() -> Set<Int32> {
        var set: Set<Int32> = []
        var cf: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&cf) == kIOReturnSuccess, let dict = cf?.takeRetainedValue() else { return set }
        let types: Set<String> = ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion",
                                  "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep"]
        for (k, v) in dict as NSDictionary {
            guard let pid = (k as? NSNumber)?.int32Value, let arr = v as? [[String: Any]] else { continue }
            if arr.contains(where: { types.contains($0["AssertType"] as? String ?? "") }) { set.insert(pid) }
        }
        return set
    }
}

// MARK: - Monitor (main-actor state the UI reads)

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var memory = MemoryInfo()
    @Published var battery = BatteryInfo()
    @Published var apps: [AppUsage] = []
    @Published var flagged: [FlaggedApp] = []
    let bar = BarState()

    var onNewFlags: (([FlaggedApp]) -> Void)?

    /// Faster polling while the popover is open, slow when it is closed.
    var uiVisible = false {
        didSet {
            guard uiVisible != oldValue else { return }
            schedule()
            if uiVisible { tick() }
        }
    }

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "sentinel.sampler", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var lastActive: [String: Date] = [:]
    private var snoozed: [String: Date] = [:]
    private var lastAlerted: [String: Date] = [:]
    private let startedAt = Date()
    private var lastAppsKey = ""
    private var lastFlagKey = ""

    private let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.loginwindow", "com.apple.controlcenter", "com.afapps.sentinel"
    ]

    // MARK: lifecycle

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            Task { @MainActor in self?.lastActive[path] = Date() }
        }
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: uiVisible ? 3 : 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1
    }

    // MARK: user actions

    func stop(_ id: String, force: Bool = false) {
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == id {
            if force { app.forceTerminate() } else { app.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.tick() }
    }

    func snooze(_ id: String, hours: Double = 1) {
        snoozed[id] = Date().addingTimeInterval(hours * 3600)
        flagged.removeAll { $0.id == id }
    }

    func ignoreForever(bundleID: String, id: String) {
        var list = ignoredIDs
        if !list.contains(bundleID) { list.append(bundleID) }
        UserDefaults.standard.set(list, forKey: "ignored")
        flagged.removeAll { $0.id == id }
    }

    func unignore(_ bundleID: String) {
        UserDefaults.standard.set(ignoredIDs.filter { $0 != bundleID }, forKey: "ignored")
        objectWillChange.send()
    }

    var ignoredIDs: [String] { UserDefaults.standard.stringArray(forKey: "ignored") ?? [] }

    // MARK: sampling cycle

    private func tick() {
        guard !Demo.enabled else { return }
        guard !busy else { return }
        busy = true

        // cheap, main-thread-only reads
        var infos: [String: RunInfo] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy != .prohibited {
            guard let path = a.bundleURL?.path, !path.hasPrefix("/System/") else { continue }
            let bid = a.bundleIdentifier ?? path
            if protectedIDs.contains(bid) { continue }
            infos[path] = RunInfo(path: path, bundleID: bid,
                                  name: a.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                  launch: a.launchDate)
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        if let f = front { lastActive[f] = Date() }
        let wanted = Set(infos.keys)

        // the expensive part runs on a background queue
        queue.async { [sampler, weak self] in
            let s = sampler.sample(wanted: wanted)
            Task { @MainActor in
                self?.apply(s, infos: infos, front: front)
                self?.busy = false
            }
        }
    }

    private func apply(_ s: Sample, infos: [String: RunInfo], front: String?) {
        if s.memory != memory { memory = s.memory }
        if s.battery != battery { battery = s.battery }
        if bar.percent != s.memory.percent { bar.percent = s.memory.percent }

        let now = Date()
        var usages: [AppUsage] = []
        for (path, g) in s.groups {
            guard let info = infos[path] else { continue }
            let baseline = max(startedAt, info.launch ?? startedAt)
            let idle = now.timeIntervalSince(lastActive[path] ?? baseline)
            usages.append(AppUsage(
                id: path, name: info.name, bundleID: info.bundleID, footprint: g.footprint,
                cpu: g.cpu, cpuAvg: g.cpuAvg, energyMW: g.energyMW, isFrontmost: path == front,
                hasWindow: g.hasWindow, awake: g.awake, idle: idle, icon: IconCache.shared.icon(for: path)))
        }
        usages.sort { $0.footprint > $1.footprint }

        if uiVisible {
            let key = usages.map { "\($0.id)\($0.footprint >> 20)\(Int($0.cpu))\(Int($0.idle / 60))" }.joined()
            if key != lastAppsKey { lastAppsKey = key; apps = usages }
        }
        analyze(usages)
    }

    // MARK: analysis

    private func analyze(_ usages: [AppUsage]) {
        let rules = FlagRules.current()
        let popups = (UserDefaults.standard.object(forKey: "popupEnabled") as? Bool) ?? true
        let ignored = Set(ignoredIDs)
        let now = Date()
        snoozed = snoozed.filter { $0.value > now }

        var result: [FlaggedApp] = []
        for u in usages {
            if ignored.contains(u.bundleID) || snoozed[u.id] != nil { continue }
            let reasons = rules.reasons(for: u, memoryPressure: memory.pressure, battery: battery)
            if reasons.isEmpty { continue }
            result.append(FlaggedApp(id: u.id, name: u.name, bundleID: u.bundleID, icon: u.icon,
                                     footprint: u.footprint, cpu: u.cpuAvg, idle: u.idle, reasons: reasons))
        }

        let key = result.map { $0.id + $0.reasons.joined() }.joined()
        if key != lastFlagKey { lastFlagKey = key; flagged = result }
        if bar.alert != !result.isEmpty { bar.alert = !result.isEmpty }

        guard popups else { return }
        let fresh = result.filter { f in
            if let t = lastAlerted[f.id], now.timeIntervalSince(t) < 1800 { return false }
            return true
        }
        if !fresh.isEmpty {
            for f in fresh { lastAlerted[f.id] = now }
            onNewFlags?(fresh)
        }
    }
}
