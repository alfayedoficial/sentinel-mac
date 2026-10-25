import AppKit
import SwiftUI

/// Demo mode is only used to produce the screenshots in the docs: `Sentinel --snapshot <folder>`.
/// It fills the app with sample data and switches off every real scan, so no personal information is ever shown.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--snapshot")
    static var outputFolder: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1], isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-snapshots", isDirectory: true)
    }
}

@MainActor
enum DemoData {
    static func apply() {
        let GB: UInt64 = 1_073_741_824
        let MB: UInt64 = 1_048_576
        let home = FileManager.default.homeDirectoryForCurrentUser
        func path(_ p: String) -> URL { home.appendingPathComponent(p) }

        // memory, battery, disk
        let monitor = Monitor.shared
        monitor.memory = MemoryInfo(total: 16 * GB, used: UInt64(9.3 * Double(GB)), wired: 2 * GB, compressed: GB / 2, pressure: 1)
        monitor.battery = BatteryInfo(hasBattery: true, percent: 72, charging: false, onAC: false, minutesRemaining: 318)
        monitor.bar.percent = 58
        let hub = Hub.shared
        hub.disk.total = 994 * Int64(GB) / 1
        hub.disk.free = 312 * Int64(GB)
        hub.disk.trash = Int64(1.2 * Double(GB))

        // running apps
        func app(_ name: String, _ p: String, mb: UInt64, cpu: Double = 0, idle: Double, window: Bool, front: Bool = false) -> AppUsage {
            AppUsage(id: p, name: name, bundleID: "com.demo.\(name.lowercased())", footprint: mb * MB, cpu: cpu, cpuAvg: cpu,
                     energyMW: 0, isFrontmost: front, hasWindow: window, awake: false, idle: idle * 60, icon: IconCache.shared.icon(for: p))
        }
        let apps = [
            app("Safari", "/Applications/Safari.app", mb: 1420, cpu: 4, idle: 3, window: true),
            app("Music", "/System/Applications/Music.app", mb: 610, cpu: 0, idle: 140, window: false),
            app("Mail", "/System/Applications/Mail.app", mb: 430, cpu: 1, idle: 45, window: false),
            app("Photos", "/System/Applications/Photos.app", mb: 380, cpu: 0, idle: 8, window: true),
            app("Maps", "/System/Applications/Maps.app", mb: 240, cpu: 0, idle: 12, window: true),
            app("Notes", "/System/Applications/Notes.app", mb: 150, cpu: 0, idle: 6, window: true),
            app("Calendar", "/System/Applications/Calendar.app", mb: 120, cpu: 0, idle: 9, window: true),
        ]
        monitor.apps = apps
        monitor.flagged = [
            FlaggedApp(id: apps[1].id, name: "Music", bundleID: apps[1].bundleID, icon: apps[1].icon, footprint: apps[1].footprint, cpu: 0, idle: apps[1].idle,
                       reasons: ["No visible window and unused for 2 h 20 min, yet it still holds 610 MB of memory."]),
            FlaggedApp(id: apps[2].id, name: "Mail", bundleID: apps[2].bundleID, icon: apps[2].icon, footprint: apps[2].footprint, cpu: 1, idle: apps[2].idle,
                       reasons: ["No visible window and unused for 45 min, yet it still holds 430 MB of memory."]),
        ]
        monitor.bar.alert = true

        // caches
        func cache(_ name: String, _ cat: String, mb: Int64, days: Double, inUse: Bool = false, system: Bool = false) -> CacheItem {
            CacheItem(url: path("Library/Caches/\(name)"), name: name, category: cat, size: mb * 1_048_576,
                      lastModified: Date().addingTimeInterval(-days * 86400), inUse: inUse, isSystem: system)
        }
        hub.cleaner.items = [
            cache("com.example.editor", "App caches", mb: 1840, days: 74),
            cache("com.example.video-tool", "App caches", mb: 960, days: 112),
            cache("Homebrew", "App caches", mb: 540, days: 48),
            cache("com.apple.Safari", "App caches", mb: 320, days: 40, system: true),
            cache("com.example.chat", "App caches", mb: 210, days: 35, inUse: true),
            cache("DiagnosticReports", "Logs", mb: 160, days: 90),
            cache("Demo-App-abcdef", "Xcode build data", mb: 2400, days: 120),
            cache("uv", "Developer tool caches", mb: 3100, days: 66),
        ]
        hub.cleaner.selected = Set(hub.cleaner.items.filter { !$0.inUse && !$0.isSystem }.map { $0.id })
        hub.cleaner.range = .month
        hub.cleaner.state = .report

        // big files and duplicates
        func big(_ p: String, mb: Int64, days: Double) -> BigFile { BigFile(url: path(p), size: mb * 1_048_576, modified: Date().addingTimeInterval(-days * 86400)) }
        hub.bigFiles.files = [big("Movies/Family-trip-4K.mov", mb: 3200, days: 210), big("Downloads/old-backup.zip", mb: 1850, days: 400),
                              big("Downloads/Installer-1.4.dmg", mb: 920, days: 130), big("Documents/Archive/Project-2022.tar", mb: 640, days: 700)]
        hub.bigFiles.selected = Set(hub.bigFiles.files.prefix(2).map { $0.id })
        hub.bigFiles.done = true
        func dup(_ p: String, mb: Int64, days: Double) -> DupFile { DupFile(url: path(p), size: mb * 1_048_576, modified: Date().addingTimeInterval(-days * 86400)) }
        let g1 = DupGroup(id: "g1", files: [dup("Documents/Reports/Q3-summary.pdf", mb: 48, days: 90), dup("Downloads/Q3-summary.pdf", mb: 48, days: 20), dup("Desktop/Q3-summary (1).pdf", mb: 48, days: 3)])
        let g2 = DupGroup(id: "g2", files: [dup("Movies/clip-final.mp4", mb: 310, days: 60), dup("Downloads/clip-final.mp4", mb: 310, days: 30)])
        hub.dups.groups = [g1, g2]
        hub.dups.remove = Set([g1.files[1], g1.files[2], g2.files[1]].map { $0.id })
        hub.dups.done = true

        // startup items
        hub.startup.items = [
            StartupItem(id: "s1", kind: .userAgent, label: "com.unknown.agent", name: "unknown agent", path: "/tmp/agent.plist", program: "/tmp/.x/agent",
                        running: true, broken: false, suspicious: "Runs a command that uses “curl”, typical of programs that download and run code."),
            StartupItem(id: "s2", kind: .systemAgent, label: "com.oldvendor.updater", name: "oldvendor updater", path: "/Library/LaunchAgents/x.plist",
                        program: "/Applications/OldVendor.app/Contents/MacOS/updater", running: false, broken: true),
            StartupItem(id: "s3", kind: .userAgent, label: "com.example.sync", name: "Example Sync", path: "/x/sync.plist", program: "/Applications/Sync.app/Contents/MacOS/sync", running: true, broken: false),
            StartupItem(id: "s4", kind: .loginItem, label: "Printer Helper", name: "Printer Helper", path: "/Applications/Printer Helper.app", program: nil, running: false, broken: false),
            StartupItem(id: "s5", kind: .systemDaemon, label: "com.example.vpn", name: "Example VPN", path: "/Library/LaunchDaemons/vpn.plist", program: "/Library/PrivilegedHelperTools/vpn", running: true, broken: false),
        ]
        hub.startup.loaded = true

        // uninstaller
        func inst(_ name: String, _ p: String, mb: Int64) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: p), name: name, bundleID: "com.demo.\(name.lowercased())", size: mb * 1_048_576)
        }
        hub.uninstaller.apps = [inst("Safari", "/Applications/Safari.app", mb: 410), inst("Music", "/System/Applications/Music.app", mb: 380),
                                inst("Photos", "/System/Applications/Photos.app", mb: 360), inst("Mail", "/System/Applications/Mail.app", mb: 220),
                                inst("Maps", "/System/Applications/Maps.app", mb: 180), inst("Notes", "/System/Applications/Notes.app", mb: 95),
                                inst("Calendar", "/System/Applications/Calendar.app", mb: 70)]

        // space lens
        func lens(_ n: String, gb: Double, dir: Bool = true) -> LensEntry { LensEntry(url: path(n), isDir: dir, size: Int64(gb * Double(GB))) }
        hub.lens.entries = [lens("Documents", gb: 24.1), lens("Movies", gb: 18.4), lens("Library", gb: 12.2), lens("Downloads", gb: 6.3),
                            lens("Pictures", gb: 4.1), lens("Projects", gb: 2.6), lens("Desktop", gb: 1.2), lens("Music", gb: 0.8)]
        hub.lens.computing = false

        // history
        let h = Date()
        HistoryLog.shared.loadDemo([
            HistoryEntry(date: h.addingTimeInterval(-300), kind: "Cache", name: "com.example.editor", originalPath: "/x", trashedPath: "/t/a", size: 1_840 * 1_048_576),
            HistoryEntry(date: h.addingTimeInterval(-3600), kind: "Uninstalled app", name: "Old Player.app", originalPath: "/x", trashedPath: "/t/b", size: 410 * 1_048_576),
            HistoryEntry(date: h.addingTimeInterval(-86400), kind: "Duplicate", name: "Q3-summary (1).pdf", originalPath: "/x", trashedPath: "/t/c", size: 48 * 1_048_576),
            HistoryEntry(date: h.addingTimeInterval(-90000), kind: "Big old file", name: "old-backup.zip", originalPath: "/x", trashedPath: "/t/d", size: 1_850 * 1_048_576, restored: true),
        ])

        // similar photos (generated pictures, so no real photo is ever shown)
        func photo(_ name: String, w: Int, h: Int, mb: Double, days: Double, hash: UInt64, seed: Int, tweak: Double) -> SimilarPhoto {
            let u = path("Pictures/\(name)")
            Thumbs.shared.demo[u.path] = DemoImages.scene(seed: seed, tweak: tweak)
            return SimilarPhoto(url: u, size: Int64(mb * 1_048_576), width: w, height: h, modified: Date().addingTimeInterval(-days * 86400), hash: hash)
        }
        let pg1 = SimilarGroup(id: "p1", items: [photo("IMG_2041.jpg", w: 4032, h: 3024, mb: 3.8, days: 40, hash: 1, seed: 1, tweak: 0),
                                                photo("IMG_2041 (1).jpg", w: 2016, h: 1512, mb: 0.9, days: 38, hash: 2, seed: 1, tweak: 0.18),
                                                photo("IMG_2042.jpg", w: 4032, h: 3024, mb: 3.6, days: 40, hash: 3, seed: 1, tweak: -0.12)])
        let pg2 = SimilarGroup(id: "p2", items: [photo("sunset-final.png", w: 3000, h: 2000, mb: 6.1, days: 90, hash: 4, seed: 2, tweak: 0),
                                                photo("sunset-final-edit.jpg", w: 3000, h: 2000, mb: 1.2, days: 60, hash: 5, seed: 2, tweak: 0.25)])
        hub.photos.groups = [pg1, pg2]
        hub.photos.remove = Set([pg1.items[1], pg1.items[2], pg2.items[1]].map { $0.id })
        hub.photos.done = true

        // similar files
        func sf(_ n: String, _ folder: String, kb: Int64, days: Double) -> SimilarFile {
            SimilarFile(url: path("\(folder)/\(n)"), size: kb * 1024, modified: Date().addingTimeInterval(-days * 86400))
        }
        hub.similarFiles.groups = [
            SimilarFileGroup(id: "quarterly-report.pdf", items: [sf("Quarterly-Report-final.pdf", "Documents", kb: 4200, days: 3), sf("Quarterly-Report (1).pdf", "Downloads", kb: 4100, days: 20), sf("Quarterly-Report copy.pdf", "Desktop", kb: 3900, days: 55)]),
            SimilarFileGroup(id: "budget.xlsx", items: [sf("Budget-v3.xlsx", "Documents", kb: 860, days: 9), sf("Budget-v2.xlsx", "Documents", kb: 840, days: 30), sf("Budget-v1.xlsx", "Documents", kb: 800, days: 70)]),
        ]
        hub.similarFiles.done = true

        // updater banner (sample)
        let up = Updater.shared
        up.currentVersion = "1.1.0"
        up.state = .available(ReleaseInfo(tag: "v1.1.1", version: "1.1.1",
                                          notes: "Settings now always has a Check for updates button and shows when it last checked.",
                                          zipURL: URL(string: "https://github.com/alfayedoficial/sentinel-mac/releases/latest/download/Sentinel.zip")!,
                                          checksumURL: nil, pageURL: URL(string: "https://github.com/alfayedoficial/sentinel-mac/releases/latest")!))
        up.lastChecked = Date().addingTimeInterval(-120)

        // threat watch
        ThreatWatch.shared.threats = [
            Threat(id: "p1", pid: 4242, pids: [4242], name: "xmrig", path: "/private/tmp/.cache/xmrig", cpu: 187, severity: .high,
                   reasons: ["Its name matches the cryptocurrency miner “xmrig”.", "Its arguments contain “stratum+tcp://”, which is used to connect to mining pools."],
                   args: "-o stratum+tcp://pool.example.com:3333 --donate-level 1", sign: .unsigned, plistPath: nil),
        ]
        ThreatWatch.shared.outside = [
            OutsideProc(id: "o1", name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres", cpu: 2, sign: .adhoc),
            OutsideProc(id: "o2", name: "syncthing", path: "/opt/homebrew/bin/syncthing", cpu: 1, sign: .adhoc),
            OutsideProc(id: "o3", name: "node", path: "/usr/local/bin/node", cpu: 0, sign: .developer),
        ]
        ThreatWatch.shared.lastScan = Date()
    }
}

/// Pictures drawn in code for the screenshots (a sky, a sun and hills), so no real photo is ever used.
enum DemoImages {
    static func scene(seed: Int, tweak: Double) -> NSImage {
        let size = NSSize(width: 220, height: 220)
        let img = NSImage(size: size)
        img.lockFocus()
        let palettes: [[NSColor]] = [
            [NSColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1), NSColor(red: 0.45, green: 0.35, blue: 0.75, alpha: 1)],
            [NSColor(red: 0.99, green: 0.78, blue: 0.40, alpha: 1), NSColor(red: 0.85, green: 0.30, blue: 0.45, alpha: 1)],
        ]
        let p = palettes[(seed - 1) % palettes.count]
        let t = CGFloat(tweak)
        NSGradient(starting: p[0].blended(withFraction: max(0, t), of: .white) ?? p[0], ending: p[1].blended(withFraction: max(0, -t), of: .black) ?? p[1])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)
        NSColor(white: 1, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 120 + t * 20, y: 120, width: 56, height: 56)).fill()
        NSColor(red: 0.12, green: 0.14, blue: 0.28, alpha: 0.9).setFill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: 0, y: 0)); hills.line(to: NSPoint(x: 0, y: 70))
        hills.curve(to: NSPoint(x: 110, y: 60), controlPoint1: NSPoint(x: 40, y: 110), controlPoint2: NSPoint(x: 70, y: 30))
        hills.curve(to: NSPoint(x: 220, y: 80), controlPoint1: NSPoint(x: 150, y: 90), controlPoint2: NSPoint(x: 190, y: 40))
        hills.line(to: NSPoint(x: 220, y: 0)); hills.close(); hills.fill()
        img.unlockFocus()
        return img
    }
}
