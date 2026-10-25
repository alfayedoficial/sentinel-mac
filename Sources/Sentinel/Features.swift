import AppKit
import CryptoKit
import SwiftUI

// MARK: - Shell helpers

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func osascriptOutput(_ script: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs a shell command with the standard macOS administrator password prompt.
func runAdmin(_ cmd: String) -> Bool {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return Trasher.osascript("do shell script \"\(esc)\" with administrator privileges")
}

func runCapture(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Startup manager

enum StartupKind: String {
    case loginItem = "Login item"
    case userAgent = "Background agent"
    case systemAgent = "System agent"
    case systemDaemon = "System service"
    var needsAdmin: Bool { self == .systemAgent || self == .systemDaemon }
}

struct StartupItem: Identifiable, Hashable {
    let id: String
    let kind: StartupKind
    let label: String
    let name: String
    let path: String?
    let program: String?
    let running: Bool
    let broken: Bool
    var suspicious: String? = nil
}

@MainActor
final class StartupManager: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var message: String?

    var brokenCount: Int { items.filter { $0.broken }.count }

    func load() {
        guard !Demo.enabled else { return }
        guard !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let found = StartupManager.scan()
            await self?.finish(found)
        }
    }

    private func finish(_ list: [StartupItem]) {
        withAnimation(.spring(duration: 0.4)) { items = list }
        loading = false
        loaded = true
    }

    /// Switches an item off: stops it and moves its file out of the way (to Trash for user items).
    func disable(_ item: StartupItem) {
        Task.detached { [weak self] in
            let uid = getuid()
            var ok = false
            switch item.kind {
            case .loginItem:
                ok = Trasher.osascript("tell application \"System Events\" to delete login item \"\(item.name)\"")
            case .userAgent:
                _ = runCapture("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
                if let p = item.path { ok = Trasher.trash(URL(fileURLWithPath: p), kind: "Startup item") }
            case .systemAgent, .systemDaemon:
                guard let p = item.path else { break }
                switch PrivilegedHelper.prepare() {
                case .ready:
                    let r = await PrivilegedHelper.disable(label: item.label, path: p)
                    ok = r.0
                case .needsApproval:
                    await self?.askForApproval()
                    return
                case .unavailable:
                    // helper not usable on this Mac: fall back to the standard password prompt
                    let domain = item.kind == .systemAgent ? "gui/\(uid)" : "system"
                    let cmd = "launchctl bootout \(domain)/\(item.label) 2>/dev/null; mkdir -p /Library/SentinelDisabled; mv \(shQuote(p)) /Library/SentinelDisabled/"
                    ok = runAdmin(cmd)
                }
            }
            await self?.afterDisable(item, ok: ok)
        }
    }

    private func askForApproval() {
        message = "One-time step: switch on Sentinel in System Settings → Login Items & Extensions, then tap Turn off again."
        PrivilegedHelper.openApprovalSettings()
    }

    private func afterDisable(_ item: StartupItem, ok: Bool) {
        message = ok ? "\(item.name) switched off." : "Could not switch off \(item.name)."
        loading = false
        load()
    }

    /// Launch agents and daemons only (no Automation permission needed).
    nonisolated static func scanAgents() -> [StartupItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let running = runningLabels()
        var out: [StartupItem] = []
        let dirs: [(URL, StartupKind)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        for (dir, kind) in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "plist" {
                guard let d = NSDictionary(contentsOf: f) as? [String: Any] else { continue }
                let label = (d["Label"] as? String) ?? f.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
                var broken = false
                if let p = program, p.hasPrefix("/") { broken = !fm.fileExists(atPath: p) }
                let argv = (d["ProgramArguments"] as? [String]) ?? []
                out.append(StartupItem(id: f.path, kind: kind, label: label, name: prettyName(label, program),
                                       path: f.path, program: program, running: running.contains(label), broken: broken,
                                       suspicious: ThreatRules.suspiciousLaunchItem(program: program, arguments: Array(argv.dropFirst()))))
            }
        }
        return out
    }

    nonisolated static func scan() -> [StartupItem] {
        let fm = FileManager.default
        var out = scanAgents()
        if let names = osascriptOutput("tell application \"System Events\" to get the name of every login item"), !names.isEmpty {
            let n = names.components(separatedBy: ", ")
            let p = (osascriptOutput("tell application \"System Events\" to get the path of every login item") ?? "")
                .components(separatedBy: ", ")
            for (i, name) in n.enumerated() {
                let path = i < p.count ? p[i] : nil
                out.append(StartupItem(id: "login:\(name)", kind: .loginItem, label: name, name: name, path: path,
                                       program: path, running: false,
                                       broken: path.map { !fm.fileExists(atPath: $0) } ?? false))
            }
        }
        return out.sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
    }

    private nonisolated static func rank(_ i: StartupItem) -> Int { i.suspicious != nil ? 0 : i.broken ? 1 : 2 }

    nonisolated static func prettyName(_ label: String, _ program: String?) -> String {
        if let p = program, let r = p.range(of: ".app/") {
            let app = String(p[..<r.lowerBound])
            return URL(fileURLWithPath: app).lastPathComponent
        }
        let parts = label.split(separator: ".")
        if parts.count > 2 { return parts.dropFirst(parts.first == "com" || parts.first == "org" || parts.first == "net" ? 1 : 0).joined(separator: " ") }
        return label
    }

    nonisolated static func runningLabels() -> Set<String> {
        var set: Set<String> = []
        for line in runCapture("/bin/launchctl", ["list"]).split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 3, cols[0] != "-" { set.insert(String(cols[2])) }
        }
        return set
    }
}

// MARK: - Space Lens

struct LensEntry: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    var size: Int64?
    var id: String { url.path }
}

@MainActor
final class SpaceLens: ObservableObject {
    @Published var stack: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    @Published var entries: [LensEntry] = []
    @Published var computing = false
    @Published var message: String?
    private var generation = 0

    var current: URL { stack.last ?? FileManager.default.homeDirectoryForCurrentUser }
    var maxSize: Int64 { max(1, entries.compactMap { $0.size }.max() ?? 1) }

    func load() {
        guard !Demo.enabled else { return }
        generation += 1
        let gen = generation
        let dir = current
        entries = []
        computing = true
        Task.detached { [weak self] in
            let kids = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
            var list: [LensEntry] = kids.compactMap { u in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { return nil }
                return LensEntry(url: u, isDir: v?.isDirectory ?? false, size: nil)
            }
            list.sort { $0.url.lastPathComponent.lowercased() < $1.url.lastPathComponent.lowercased() }
            await self?.setEntries(list, gen: gen)
            for e in list {
                let size = e.isDir ? directorySize(e.url)
                    : Int64((try? e.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                await self?.setSize(e.id, size, gen: gen)
            }
            await self?.finish(gen: gen)
        }
    }

    private func setEntries(_ l: [LensEntry], gen: Int) { if gen == generation { entries = l } }
    private func setSize(_ id: String, _ s: Int64, gen: Int) {
        guard gen == generation, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].size = s
    }
    private func finish(gen: Int) {
        guard gen == generation else { return }
        withAnimation(.spring(duration: 0.5)) {
            entries.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        }
        computing = false
    }

    func open(_ e: LensEntry) {
        guard e.isDir else { NSWorkspace.shared.activateFileViewerSelecting([e.url]); return }
        stack.append(e.url)
        load()
    }

    func jump(to index: Int) {
        guard index < stack.count - 1 else { return }
        stack = Array(stack.prefix(index + 1))
        load()
    }

    func up() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        load()
    }

    func trash(_ e: LensEntry) {
        Task.detached { [weak self] in
            let ok = Trasher.trash(e.url, size: e.size ?? 0, kind: "Space Lens")
            await self?.afterTrash(e, ok: ok)
        }
    }

    private func afterTrash(_ e: LensEntry, ok: Bool) {
        withAnimation(.spring(duration: 0.4)) {
            if ok { entries.removeAll { $0.id == e.id } }
            message = ok ? "Moved \(e.url.lastPathComponent) to Trash." : "Could not move \(e.url.lastPathComponent)."
        }
    }
}

// MARK: - Duplicate finder

struct DupFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: String { url.path }
}

struct DupGroup: Identifiable, Hashable {
    let id: String
    var files: [DupFile]
    var size: Int64 { files.first?.size ?? 0 }
}

@MainActor
final class DuplicateFinder: ObservableObject {
    @Published var minMB: Double = 5
    @Published var groups: [DupGroup] = []
    @Published var remove: Set<String> = []
    @Published var scanning = false
    @Published var done = false
    @Published var status = ""
    @Published var message: String?

    var reclaimable: Int64 {
        groups.flatMap { $0.files }.filter { remove.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !Demo.enabled else { return }
        guard !scanning else { return }
        scanning = true
        done = false
        message = nil
        groups = []
        remove = []
        let minBytes = Int64(minMB * 1_048_576)
        Task.detached { [weak self] in
            let found = DuplicateFinder.find(minBytes: minBytes) { text in
                Task { @MainActor in self?.status = text }
            }
            await self?.finish(found)
        }
    }

    private func finish(_ g: [DupGroup]) {
        let sorted = g.sorted { $0.size * Int64($0.files.count) > $1.size * Int64($1.files.count) }
        groups = sorted
        // keep the oldest copy of each group, mark the rest
        var marks: Set<String> = []
        for grp in sorted {
            let keep = grp.files.min { $0.modified < $1.modified }
            for f in grp.files where f.id != keep?.id { marks.insert(f.id) }
        }
        remove = marks
        scanning = false
        withAnimation(.spring(duration: 0.5)) { done = true }
    }

    func keep(_ file: DupFile, in group: DupGroup) {
        for f in group.files { remove.insert(f.id) }
        remove.remove(file.id)
    }

    func toggle(_ file: DupFile) {
        if remove.contains(file.id) { remove.remove(file.id) } else { remove.insert(file.id) }
    }

    func trashMarked() {
        let targets = groups.flatMap { $0.files }.filter { remove.contains($0.id) }
        Task.detached { [weak self] in
            var freed: Int64 = 0
            var failed = 0
            var gone: Set<String> = []
            for t in targets { if Trasher.trash(t.url, size: t.size, kind: "Duplicate") { freed += t.size; gone.insert(t.id) } else { failed += 1 } }
            await self?.afterTrash(gone, freed: freed, failed: failed)
        }
    }

    private func afterTrash(_ gone: Set<String>, freed: Int64, failed: Int) {
        withAnimation(.spring(duration: 0.4)) {
            groups = groups.compactMap { g in
                var g = g
                g.files.removeAll { gone.contains($0.id) }
                return g.files.count > 1 ? g : nil
            }
            remove.subtract(gone)
            message = failed == 0 ? "Moved \(fmtFile(freed)) of duplicates to Trash." : "Moved \(fmtFile(freed)); \(failed) failed."
        }
    }

    nonisolated static func find(minBytes: Int64, roots: [URL]? = nil, progress: (String) -> Void) -> [DupGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanRoots = roots ?? ["Downloads", "Desktop", "Movies", "Documents", "Music", "Pictures"].map { home.appendingPathComponent($0) }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var bySize: [Int64: [DupFile]] = [:]
        var seen = 0
        for root in scanRoots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in en {
                if f.pathComponents.contains("node_modules") { en.skipDescendants(); continue }
                guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, Int64(size) >= minBytes else { continue }
                seen += 1
                if seen % 200 == 0 { progress("Looked at \(seen) files…") }
                bySize[Int64(size), default: []].append(DupFile(url: f, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
            }
        }
        var result: [DupGroup] = []
        let candidates = bySize.values.filter { $0.count > 1 }
        var done = 0
        for group in candidates {
            var byQuick: [String: [DupFile]] = [:]
            for f in group { if let h = quickHash(f.url, size: f.size) { byQuick[h, default: []].append(f) } }
            for q in byQuick.values where q.count > 1 {
                var byFull: [String: [DupFile]] = [:]
                for f in q { if let h = fullHash(f.url) { byFull[h, default: []].append(f) } }
                for (h, files) in byFull where files.count > 1 { result.append(DupGroup(id: h, files: files)) }
            }
            done += 1
            progress("Comparing \(done) of \(candidates.count) groups…")
        }
        return result
    }

    nonisolated static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: 65536) else { return nil }
        hasher.update(data: head)
        if size > 131_072 {
            try? h.seek(toOffset: UInt64(size - 65536))
            if let tail = try? h.read(upToCount: 65536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let d = try? h.read(upToCount: 4 << 20), !d.isEmpty else { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Shared container for the tools

enum ToolKind: String, Identifiable, CaseIterable {
    case smart, uninstall, bigFiles, duplicates, spaceLens, startup, maintenance, history, threats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart Care"
        case .uninstall: "Uninstaller"
        case .bigFiles: "Big Old Files"
        case .duplicates: "Duplicates"
        case .spaceLens: "Space Lens"
        case .startup: "Startup Manager"
        case .maintenance: "Maintenance"
        case .history: "History"
        case .threats: "Threat Watch"
        }
    }
    var blurb: String {
        switch self {
        case .smart: "One scan for everything"
        case .uninstall: "Apps + all their data"
        case .bigFiles: "Large files you forgot"
        case .duplicates: "Same file, many copies"
        case .spaceLens: "See what fills your disk"
        case .startup: "Login items & helpers"
        case .maintenance: "Quick Mac fixes"
        case .history: "Restore what you cleaned"
        case .threats: "Miners & hidden programs"
        }
    }
    var icon: String {
        switch self {
        case .smart: "wand.and.stars"
        case .uninstall: "xmark.app.fill"
        case .bigFiles: "doc.zipper"
        case .duplicates: "square.on.square.fill"
        case .spaceLens: "chart.pie.fill"
        case .startup: "power.circle.fill"
        case .maintenance: "wrench.adjustable.fill"
        case .history: "clock.arrow.circlepath"
        case .threats: "shield.lefthalf.filled.badge.checkmark"
        }
    }
    var style: TileStyle {
        switch self {
        case .smart: .clean
        case .uninstall: .remove
        case .bigFiles: .bigFiles
        case .duplicates: .duplicates
        case .spaceLens: .lens
        case .startup: .startup
        case .maintenance: .maintenance
        case .history: .history
        case .threats: .trash
        }
    }
}

@MainActor
final class Hub: ObservableObject {
    static let shared = Hub()
    let cleaner = CacheCleaner()
    let disk = DiskStats()
    let uninstaller = Uninstaller()
    let bigFiles = BigFileFinder()
    let startup = StartupManager()
    let lens = SpaceLens()
    let dups = DuplicateFinder()
}
