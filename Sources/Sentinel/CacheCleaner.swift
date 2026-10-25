import AppKit
import SwiftUI

enum CleanRange: String, CaseIterable, Identifiable {
    case week, month, threeMonths, sixMonths, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "1 Week"
        case .month: "1 Month"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "1 Year"
        }
    }
    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .sixMonths: 180
        case .year: 365
        }
    }
    var cutoff: Date { Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date() }
}

struct CacheItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let category: String
    let size: Int64
    let lastModified: Date
    let inUse: Bool
    let isSystem: Bool
    var id: String { url.path }
}

enum CleanState: Equatable {
    case idle
    case scanning
    case report
    case cleaning
    case done(freed: Int64, failed: Int)
}

@MainActor
final class CacheCleaner: ObservableObject {
    @Published var range: CleanRange = .month
    @Published var state: CleanState = .idle
    @Published var items: [CacheItem] = []
    @Published var selected: Set<String> = []
    @Published var scannedFolders = 0
    @Published var currentFolder = ""
    @Published var permanent = false

    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var grouped: [(String, [CacheItem])] {
        let dict = Dictionary(grouping: items, by: { $0.category })
        return dict.map { ($0.key, $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
    }

    // MARK: scan

    func scan() {
        guard !Demo.enabled else { return }
        guard state != .scanning else { return }
        state = .scanning
        items = []
        selected = []
        scannedFolders = 0
        let cutoff = range.cutoff
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let runningNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() })

        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [CacheItem] = []
            var seen = 0
            let fm = FileManager.default
            for root in CacheCleaner.roots() {
                guard let children = try? fm.contentsOfDirectory(
                    at: root.url, includingPropertiesForKeys: nil, options: []) else { continue }
                for child in children {
                    let name = child.lastPathComponent
                    if name == ".DS_Store" || name.hasPrefix(".localized") { continue }
                    seen += 1
                    if seen % 12 == 0 { await self?.progress(name, count: seen) }
                    guard let r = CacheCleaner.evaluate(child, cutoff: cutoff), r.size >= 256 * 1024 else { continue }
                    let lower = name.lowercased()
                    let inUse = running.contains { lower == $0 || lower.hasPrefix($0) } || runningNames.contains(lower)
                    found.append(CacheItem(url: child, name: name, category: root.label, size: r.size,
                                           lastModified: r.newest, inUse: inUse,
                                           isSystem: lower.hasPrefix("com.apple.")))
                }
            }
            let result = found.sorted { $0.size > $1.size }
            await self?.finishScan(result)
        }
    }

    private func progress(_ name: String, count: Int) {
        scannedFolders = count
        currentFolder = name
    }

    private func finishScan(_ result: [CacheItem]) {
        items = result
        selected = Set(result.filter { !$0.inUse && !$0.isSystem }.map { $0.id })
        withAnimation(.spring(duration: 0.5)) { state = .report }
    }

    // MARK: clean

    func toggle(_ item: CacheItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func setAll(_ on: Bool) {
        selected = on ? Set(items.filter { !$0.inUse }.map { $0.id }) : []
    }

    func clean() {
        let targets = items.filter { selected.contains($0.id) }
        let perm = permanent
        state = .cleaning
        Task.detached(priority: .userInitiated) { [weak self] in
            var freed: Int64 = 0
            var failed = 0
            let fm = FileManager.default
            for t in targets {
                do {
                    if perm { try fm.removeItem(at: t.url) } else {
                        var res: NSURL?
                        try fm.trashItem(at: t.url, resultingItemURL: &res)
                        HistoryLog.shared.record(kind: "Cache", original: t.url, trashed: res as URL?, size: t.size)
                    }
                    freed += t.size
                } catch { failed += 1 }
            }
            await self?.finishClean(freed: freed, failed: failed)
        }
    }

    private func finishClean(freed: Int64, failed: Int) {
        items = items.filter { !selected.contains($0.id) }
        selected = []
        withAnimation(.spring(duration: 0.5)) { state = .done(freed: freed, failed: failed) }
    }

    func reset() {
        withAnimation(.spring(duration: 0.4)) { state = .idle }
        items = []
        selected = []
    }

    // MARK: filesystem

    struct Root { let label: String; let url: URL }

    nonisolated static func roots() -> [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func h(_ p: String) -> URL { home.appendingPathComponent(p, isDirectory: true) }
        return [
            Root(label: "App caches", url: h("Library/Caches")),
            Root(label: "Logs", url: h("Library/Logs")),
            Root(label: "Xcode build data", url: h("Library/Developer/Xcode/DerivedData")),
            Root(label: "Xcode device support", url: h("Library/Developer/Xcode/iOS DeviceSupport")),
            Root(label: "Developer tool caches", url: h(".cache")),
            Root(label: "Developer tool caches", url: h(".npm")),
            Root(label: "Developer tool caches", url: h(".gradle/caches")),
            Root(label: "Developer tool caches", url: h(".pub-cache")),
        ]
    }

    /// Returns total size and newest modification date, or nil when anything inside was used inside the range.
    nonisolated static func evaluate(_ url: URL, cutoff: Date) -> (size: Int64, newest: Date)? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func attrs(_ u: URL) -> (Int64, Date)? {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (Int64(v.totalFileAllocatedSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        guard let top = attrs(url) else { return nil }
        if top.1 >= cutoff { return nil }
        var size = top.0
        var newest = top.1
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir, let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in en {
                guard let a = attrs(f) else { continue }
                if a.1 >= cutoff { return nil }
                size += a.0
                if a.1 > newest { newest = a.1 }
            }
        }
        return (size, newest)
    }
}
