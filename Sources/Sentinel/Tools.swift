import AppKit
import SwiftUI

// MARK: - Trash helpers

enum Trasher {
    /// Moves to Trash. Falls back to Finder for root-owned items (e.g. App Store apps).
    static func trash(_ url: URL, size: Int64 = 0, kind: String = "Moved to Trash") -> Bool {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            HistoryLog.shared.record(kind: kind, original: url, trashed: result as URL?, size: size)
            return true
        } catch {
            let ok = finderDelete(url)
            if ok { HistoryLog.shared.record(kind: kind, original: url, trashed: nil, size: size) }
            return ok
        }
    }

    static func finderDelete(_ url: URL) -> Bool {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return osascript("tell application \"Finder\" to delete POSIX file \"\(path)\"")
    }

    static func emptyTrash() -> Bool {
        osascript("tell application \"Finder\" to empty trash")
    }

    @discardableResult
    static func osascript(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}

func directorySize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
    var total = Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
    if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                               errorHandler: { _, _ in true }) {
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
    }
    return total
}

// MARK: - Disk stats

@MainActor
final class DiskStats: ObservableObject {
    @Published var total: Int64 = 0
    @Published var free: Int64 = 0
    @Published var trash: Int64 = 0
    @Published var emptying = false

    var usedFraction: Double { total == 0 ? 0 : 1 - Double(free) / Double(total) }

    func refresh() {
        guard !Demo.enabled else { return }
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            total = Int64(v.volumeTotalCapacity ?? 0)
            free = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        Task.detached { [weak self] in
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            let size = directorySize(trash)
            await self?.setTrash(size)
        }
    }

    private func setTrash(_ s: Int64) { trash = s }

    func emptyTrash() {
        emptying = true
        Task.detached { [weak self] in
            _ = Trasher.emptyTrash()
            await self?.afterEmpty()
        }
    }

    private func afterEmpty() {
        emptying = false
        refresh()
    }
}

// MARK: - Uninstaller

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    var size: Int64
    var id: String { url.path }
}

struct Leftover: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var id: String { url.path }
}

@MainActor
final class Uninstaller: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var search = ""
    @Published var selected: InstalledApp?
    @Published var leftovers: [Leftover] = []
    @Published var removeData = true
    @Published var busy = false
    @Published var message: String?

    var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.size } }

    func load() {
        guard !Demo.enabled else { return }
        guard !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let found = Uninstaller.discover()
            await self?.setApps(found)
            for app in found {
                let size = directorySize(app.url)
                await self?.setSize(app.id, size)
            }
            await self?.doneLoading()
        }
    }

    private func setApps(_ list: [InstalledApp]) { apps = list }
    private func doneLoading() {
        withAnimation(.spring(duration: 0.4)) { apps.sort { $0.size > $1.size } }
        loading = false
    }
    private func setSize(_ id: String, _ size: Int64) {
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].size = size }
    }

    func select(_ app: InstalledApp?) {
        selected = app
        leftovers = []
        message = nil
        guard let app else { return }
        Task.detached { [weak self] in
            let found = Uninstaller.findLeftovers(for: app)
            await self?.setLeftovers(found, for: app.id)
        }
    }

    private func setLeftovers(_ l: [Leftover], for id: String) {
        if selected?.id == id { withAnimation(.spring(duration: 0.4)) { leftovers = l } }
    }

    func uninstall(_ app: InstalledApp) {
        busy = true
        let data = removeData ? leftovers : []
        for r in NSWorkspace.shared.runningApplications where r.bundleURL?.path == app.id { r.terminate() }
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var freed = app.size
            var failed = 0
            if !Trasher.trash(app.url, size: app.size, kind: "Uninstalled app") { failed += 1; freed -= app.size }
            for l in data { if Trasher.trash(l.url, size: l.size, kind: "App data") { freed += l.size } else { failed += 1 } }
            await self?.finishUninstall(app, freed: freed, failed: failed)
        }
    }

    private func finishUninstall(_ app: InstalledApp, freed: Int64, failed: Int) {
        busy = false
        if failed == 0 || freed > 0 { apps.removeAll { $0.id == app.id } }
        withAnimation(.spring(duration: 0.4)) {
            selected = nil
            leftovers = []
            message = failed == 0 ? "Moved \(app.name) to Trash — \(fmtFile(freed)) ready to free."
                                  : "\(app.name): \(failed) item(s) could not be removed."
        }
    }

    nonisolated static func discover() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [InstalledApp] = []
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if en.level > 3 { en.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                en.skipDescendants()
                let bundle = Bundle(url: url)
                let bid = bundle?.bundleIdentifier ?? url.lastPathComponent
                if bid == "com.afapps.sentinel" { continue }
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(InstalledApp(url: url, name: name, bundleID: bid, size: 0))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    nonisolated static func findLeftovers(for app: InstalledApp, library: URL? = nil) -> [Leftover] {
        let lib = library ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let folders = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                       "Saved Application State", "Logs", "HTTPStorages", "WebKit", "LaunchAgents",
                       "Application Scripts", "Cookies"]
        let bid = app.bundleID.lowercased()
        let nm = app.name.lowercased()
        var out: [Leftover] = []
        for f in folders {
            let dir = lib.appendingPathComponent(f)
            guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for k in kids {
                let n = k.lastPathComponent.lowercased()
                let stem = n.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".savedstate", with: "")
                let matchesID = bid.contains(".") && (stem == bid || stem.hasSuffix("." + bid) || stem.hasPrefix(bid + "."))
                let matchesName = (f == "Application Support" || f == "Caches" || f == "Logs") && stem == nm
                if matchesID || matchesName { out.append(Leftover(url: k, size: directorySize(k))) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

// MARK: - Large & old files

struct BigFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: String { url.path }
}

@MainActor
final class BigFileFinder: ObservableObject {
    @Published var minMB: Double = 200
    @Published var range: CleanRange = .threeMonths
    @Published var files: [BigFile] = []
    @Published var selected: Set<String> = []
    @Published var scanning = false
    @Published var done = false
    @Published var message: String?

    var selectedBytes: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !Demo.enabled else { return }
        guard !scanning else { return }
        scanning = true
        done = false
        message = nil
        files = []
        selected = []
        let minBytes = Int64(minMB * 1_048_576)
        let cutoff = range.cutoff
        Task.detached { [weak self] in
            let top = BigFileFinder.search(minBytes: minBytes, cutoff: cutoff)
            await self?.finish(top)
        }
    }

    nonisolated static func search(minBytes: Int64, cutoff: Date, roots: [URL]? = nil) -> [BigFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanRoots = roots ?? ["Downloads", "Desktop", "Movies", "Documents", "Music", "Pictures"].map { home.appendingPathComponent($0) }
        var found: [BigFile] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for root in scanRoots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in en {
                if f.pathComponents.contains("node_modules") { en.skipDescendants(); continue }
                guard let v = try? f.resourceValues(forKeys: keys),
                      v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minBytes,
                      let mod = v.contentModificationDate, mod < cutoff else { continue }
                found.append(BigFile(url: f, size: Int64(size), modified: mod))
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(200))
    }

    private func finish(_ list: [BigFile]) {
        files = list
        scanning = false
        withAnimation(.spring(duration: 0.4)) { done = true }
    }

    func toggle(_ f: BigFile) {
        if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
    }

    func trashSelected() {
        let targets = files.filter { selected.contains($0.id) }
        Task.detached { [weak self] in
            var freed: Int64 = 0
            var failed = 0
            for t in targets { if Trasher.trash(t.url, size: t.size, kind: "Big old file") { freed += t.size } else { failed += 1 } }
            await self?.afterTrash(Set(targets.map { $0.id }), freed: freed, failed: failed)
        }
    }

    private func afterTrash(_ ids: Set<String>, freed: Int64, failed: Int) {
        withAnimation(.spring(duration: 0.4)) {
            files.removeAll { ids.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
            selected = []
            message = failed == 0 ? "Moved \(fmtFile(freed)) to Trash." : "Moved \(fmtFile(freed)); \(failed) item(s) failed."
        }
    }
}
