import AppKit
import SwiftUI
import UserNotifications

// MARK: - History (what Sentinel moved to the Trash, with Restore)

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var kind: String
    var name: String
    var originalPath: String
    var trashedPath: String?
    var size: Int64
    var restored = false
}

final class HistoryLog: ObservableObject, @unchecked Sendable {
    static let shared = HistoryLog()

    @Published private(set) var entries: [HistoryEntry] = []
    /// The source of truth. `entries` is only a copy published to the UI, so rapid records never lose each other.
    private var store: [HistoryEntry] = []
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL custom: URL? = nil) {
        if let custom {
            fileURL = custom
            try? FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sentinel", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("history.json")
        }
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) { entries = list; store = list }
    }

    /// Safe to call from any thread.
    func record(kind: String, original: URL, trashed: URL?, size: Int64) {
        let e = HistoryEntry(kind: kind, name: original.lastPathComponent, originalPath: original.path,
                             trashedPath: trashed?.path, size: size)
        lock.lock()
        store.insert(e, at: 0)
        if store.count > 300 { store.removeLast(store.count - 300) }
        let snapshot = store
        lock.unlock()
        persist(snapshot)
        DispatchQueue.main.async { self.entries = snapshot }
    }

    private func persist(_ list: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Demo mode only: shows sample entries without touching the real history file.
    func loadDemo(_ list: [HistoryEntry]) { entries = list }

    func clear() {
        lock.lock(); store = []; lock.unlock()
        persist([])
        entries = []
    }

    /// Puts an item back where it came from. Returns an error message, or nil on success.
    func restore(_ e: HistoryEntry) -> String? {
        let fm = FileManager.default
        guard let t = e.trashedPath, fm.fileExists(atPath: t) else { return "It is no longer in the Trash." }
        let dest = URL(fileURLWithPath: e.originalPath)
        guard fm.fileExists(atPath: dest.deletingLastPathComponent().path) else { return "The original folder no longer exists." }
        guard !fm.fileExists(atPath: dest.path) else { return "Something with that name already exists there." }
        do { try fm.moveItem(at: URL(fileURLWithPath: t), to: dest) } catch { return error.localizedDescription }
        lock.lock()
        if let i = store.firstIndex(where: { $0.id == e.id }) { store[i].restored = true }
        let snapshot = store
        lock.unlock()
        persist(snapshot)
        entries = snapshot
        return nil
    }
}

struct HistoryView: View {
    @ObservedObject var log = HistoryLog.shared
    @State private var available: Set<UUID> = []
    @State private var message: String?
    @State private var confirmClear = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack {
                    Text("Everything Sentinel moved to the Trash. Restore works while the item is still in the Trash.")
                        .font(.system(size: 11)).foregroundStyle(Theme.t2)
                    if !log.entries.isEmpty {
                        Button("Clear") { confirmClear = true }.controlSize(.small).buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 16)
                if let m = message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.warning).padding(.horizontal, 16) }
                if log.entries.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(Theme.t2)
                        Text("Nothing yet").font(.system(size: 13, weight: .semibold))
                        Text("Items you clean will be listed here.").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(log.entries) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: e.restored ? "arrow.uturn.backward.circle.fill" : "trash.circle.fill")
                                        .font(.system(size: 18)).foregroundStyle(e.restored ? Theme.success : Theme.t2)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text("\(e.kind) · \(e.date.formatted(.relative(presentation: .named)))" + (e.size > 0 ? " · \(fmtFile(e.size))" : ""))
                                            .font(.system(size: 10)).foregroundStyle(Theme.t2).lineLimit(1)
                                    }
                                    Spacer()
                                    if e.restored { Text("Restored").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.success) }
                                    else if available.contains(e.id) {
                                        Button("Restore") { message = log.restore(e); refresh() }.controlSize(.small).buttonStyle(.bordered)
                                    }
                                }
                                .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirmClear {
                ConfirmCard(title: "Clear the history?", message: "This only clears this list. Nothing is deleted or restored.",
                            confirm: "Clear", onConfirm: { log.clear(); confirmClear = false }, onCancel: { confirmClear = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirmClear)
        .onAppear { refresh() }
    }

    /// Checked once off the main thread, never inside body.
    private func refresh() {
        if Demo.enabled { available = Set(log.entries.map { $0.id }); return }
        let list = log.entries
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Set(list.filter { e in e.trashedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }.map { $0.id })
            DispatchQueue.main.async { available = ok }
        }
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsPassword: Bool
    let run: @Sendable () -> Bool
}

private func status(_ exe: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

struct MaintenanceView: View {
    enum State { case idle, running, done, failed }
    @SwiftUI.State private var states: [String: State] = [:]

    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private var tasks: [MaintenanceTask] {
        let ls = lsregister
        return [
            MaintenanceTask(id: "dock", title: "Restart Dock", detail: "Fixes a frozen Dock, Mission Control or Launchpad", icon: "dock.rectangle",
                            needsPassword: false) { status("/usr/bin/killall", ["Dock"]) },
            MaintenanceTask(id: "finder", title: "Restart Finder", detail: "Fixes a stuck Finder or desktop", icon: "folder",
                            needsPassword: false) { status("/usr/bin/killall", ["Finder"]) },
            MaintenanceTask(id: "openwith", title: "Fix “Open With” menu", detail: "Rebuilds the list of apps for each file type", icon: "arrow.up.forward.app",
                            needsPassword: false) { status(ls, ["-kill", "-r", "-domain", "user"]) },
            MaintenanceTask(id: "quicklook", title: "Reset Quick Look", detail: "Clears preview caches when thumbnails are wrong", icon: "eye",
                            needsPassword: false) { status("/usr/bin/qlmanage", ["-r", "cache"]) },
            MaintenanceTask(id: "fonts", title: "Clear font cache", detail: "Fixes font glitches (takes effect after a restart)", icon: "textformat",
                            needsPassword: false) { status("/usr/bin/atsutil", ["databases", "-removeUser"]) },
            MaintenanceTask(id: "dns", title: "Flush DNS cache", detail: "Fixes websites that will not load after a network change", icon: "network",
                            needsPassword: true) { runAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder") },
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Quick fixes for common Mac problems. None of them delete your files.")
                    .font(.system(size: 11)).foregroundStyle(Theme.t2).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(tasks) { t in
                    let st = states[t.id] ?? .idle
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TileStyle.maintenance.gradient))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 12.5, weight: .semibold))
                            Text(t.detail + (t.needsPassword ? " · asks for your password" : ""))
                                .font(.system(size: 10.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        switch st {
                        case .running: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).transition(.scale)
                        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning).transition(.scale)
                        case .idle: EmptyView()
                        }
                        Button("Run") { run(t) }.controlSize(.small).buttonStyle(.bordered).disabled(st == .running)
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .animation(.spring(duration: 0.3), value: states)
        }
    }

    private func run(_ t: MaintenanceTask) {
        states[t.id] = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = t.run()
            DispatchQueue.main.async { states[t.id] = ok ? .done : .failed }
        }
    }
}

// MARK: - Weekly reminder

@MainActor
final class WeeklyCheck {
    static let shared = WeeklyCheck()
    private var timer: Timer?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "weeklyReminder") }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer?.tolerance = 600
        check()
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func check() {
        let d = UserDefaults.standard
        guard Self.enabled else { return }
        let last = d.object(forKey: "weeklyLast") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 7 * 86400 else { return }
        d.set(Date(), forKey: "weeklyLast")
        let cutoff = CleanRange.month.cutoff
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            let fm = FileManager.default
            for root in CacheCleaner.roots() {
                guard let kids = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil) else { continue }
                for k in kids { if let r = CacheCleaner.evaluate(k, cutoff: cutoff), r.size >= 256 * 1024 { total += r.size } }
            }
            guard total > 200 * 1_048_576 else { return }
            let c = UNMutableNotificationContent()
            c.title = "Sentinel"
            c.body = "\(fmtFile(total)) of old caches can be cleaned. Open Sentinel → Clean to review."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly", content: c, trigger: nil))
        }
    }
}
