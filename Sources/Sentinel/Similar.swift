import AppKit
import ImageIO
import SwiftUI

// MARK: - Similar photos (perceptual hash)

struct SimilarPhoto: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let width: Int
    let height: Int
    let modified: Date
    let hash: UInt64
    var id: String { url.path }
    var pixels: Int { width * height }
}

struct SimilarGroup: Identifiable, Hashable {
    let id: String
    var items: [SimilarPhoto]
    /// The photo to keep: most pixels, then biggest file, then oldest.
    var best: SimilarPhoto {
        items.max { ($0.pixels, $0.size, -$0.modified.timeIntervalSince1970) < ($1.pixels, $1.size, -$1.modified.timeIntervalSince1970) }!
    }
}

enum Sensitivity: Int, CaseIterable, Identifiable {
    case veryClose = 4, similar = 8, loose = 12
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .veryClose: "Very close"
        case .similar: "Similar"
        case .loose: "Loose"
        }
    }
    var hint: String {
        switch self {
        case .veryClose: "Resized or re-saved copies"
        case .similar: "Edited, cropped a little, other format"
        case .loose: "Burst shots and look-alikes (review carefully)"
        }
    }
}

enum PhotoHash {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// 64-bit "difference hash": compares neighbouring brightness values of a 9 x 8 miniature, so it survives resizing,
    /// re-compression and small colour changes.
    static func dHash(_ url: URL) -> (hash: UInt64, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 96]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &pixels, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if pixels[row * 9 + col] > pixels[row * 9 + col + 1] { hash |= 1 }
            }
        }
        return (hash, w, h)
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Groups indices whose hashes are within `maxDistance` of each other (directly or through a chain). Pure and tested.
    static func cluster(_ hashes: [UInt64], maxDistance: Int) -> [[Int]] {
        var parent = Array(0..<hashes.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        for i in 0..<hashes.count {
            for j in (i + 1)..<max(i + 1, hashes.count) where distance(hashes[i], hashes[j]) <= maxDistance {
                let a = find(i), b = find(j)
                if a != b { parent[a] = b }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<hashes.count { groups[find(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }   // stable order
    }
}

@MainActor
final class SimilarPhotoFinder: ObservableObject {
    @Published var sensitivity: Sensitivity = .veryClose
    @Published var groups: [SimilarGroup] = []
    @Published var remove: Set<String> = []
    @Published var scanning = false
    @Published var done = false
    @Published var status = ""
    @Published var message: String?

    nonisolated static let maxPhotos = 15_000
    var reclaimable: Int64 { groups.flatMap { $0.items }.filter { remove.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !Demo.enabled, !scanning else { return }
        scanning = true; done = false; message = nil; groups = []; remove = []
        let maxDist = sensitivity.rawValue
        Task.detached { [weak self] in
            let found = SimilarPhotoFinder.find(maxDistance: maxDist) { text in Task { @MainActor in self?.status = text } }
            await self?.finish(found)
        }
    }

    private func finish(_ g: [SimilarGroup]) {
        let sorted = g.sorted { $0.items.count > $1.items.count }
        groups = sorted
        var marks: Set<String> = []
        for grp in sorted { for p in grp.items where p.id != grp.best.id { marks.insert(p.id) } }
        remove = marks
        scanning = false
        withAnimation(.spring(duration: 0.5)) { done = true }
    }

    func keep(_ p: SimilarPhoto, in g: SimilarGroup) {
        for i in g.items { remove.insert(i.id) }
        remove.remove(p.id)
    }

    func toggle(_ p: SimilarPhoto) { if remove.contains(p.id) { remove.remove(p.id) } else { remove.insert(p.id) } }

    func trashMarked() {
        let targets = groups.flatMap { $0.items }.filter { remove.contains($0.id) }
        Task.detached { [weak self] in
            var freed: Int64 = 0, failed = 0
            var gone: Set<String> = []
            for t in targets { if Trasher.trash(t.url, size: t.size, kind: "Similar photo") { freed += t.size; gone.insert(t.id) } else { failed += 1 } }
            await self?.afterTrash(gone, freed: freed, failed: failed)
        }
    }

    private func afterTrash(_ gone: Set<String>, freed: Int64, failed: Int) {
        withAnimation(.spring(duration: 0.4)) {
            groups = groups.compactMap { g in
                var g = g; g.items.removeAll { gone.contains($0.id) }
                return g.items.count > 1 ? g : nil
            }
            remove.subtract(gone)
            message = failed == 0 ? "Moved \(fmtFile(freed)) of similar photos to Trash." : "Moved \(fmtFile(freed)); \(failed) failed."
        }
    }

    nonisolated static func find(maxDistance: Int, roots: [URL]? = nil, minPixels: Int = 90_000, minBytes: Int = 20_000, progress: (String) -> Void) -> [SimilarGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanRoots = roots ?? ["Pictures", "Downloads", "Desktop", "Documents", "Movies"].map { home.appendingPathComponent($0) }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var files: [(URL, Int64, Date)] = []
        for root in scanRoots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in en {
                if f.pathComponents.contains("node_modules") { en.skipDescendants(); continue }
                guard PhotoHash.extensions.contains(f.pathExtension.lowercased()),
                      let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, size >= minBytes else { continue }
                files.append((f, Int64(size), v.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.2 > $1.2 }
        if files.count > maxPhotos { files = Array(files.prefix(maxPhotos)) }

        var photos: [SimilarPhoto] = []
        for (i, f) in files.enumerated() {
            if i % 50 == 0 { progress("Looking at photo \(i + 1) of \(files.count)…") }
            guard let h = PhotoHash.dHash(f.0), h.width * h.height >= minPixels else { continue }
            photos.append(SimilarPhoto(url: f.0, size: f.1, width: h.width, height: h.height, modified: f.2, hash: h.hash))
        }
        progress("Comparing \(photos.count) photos…")
        return PhotoHash.cluster(photos.map { $0.hash }, maxDistance: maxDistance).map { idx in
            SimilarGroup(id: photos[idx[0]].id, items: idx.map { photos[$0] })
        }
    }
}

// MARK: - Similar files (same name family)

struct SimilarFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: String { url.path }
}

struct SimilarFileGroup: Identifiable, Hashable {
    let id: String
    var items: [SimilarFile]
    var newest: SimilarFile { items.max { $0.modified < $1.modified }! }
}

enum FileFamily {
    /// "Report (1).pdf", "report copy.PDF", "Report-2.pdf" and "Report_final_v3.pdf" all belong to the family "report.pdf".
    static func key(for name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        var base = url.deletingPathExtension().lastPathComponent.lowercased()
        let patterns = [" \\(\\d{1,3}\\)$", "[ _-]copy( \\d{1,3})?$", "[ _-]v?\\d{1,3}$", "[ _-](final|new|old|backup|bak)$", " copy$"]
        var changed = true
        while changed {
            changed = false
            for p in patterns {
                if let r = base.range(of: p, options: .regularExpression), r.lowerBound > base.startIndex {
                    base.removeSubrange(r)
                    base = base.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))   // "report - copy" -> "report"
                    changed = true
                }
            }
        }
        return base.trimmingCharacters(in: .whitespaces) + "." + ext
    }
}

@MainActor
final class SimilarFileFinder: ObservableObject {
    @Published var groups: [SimilarFileGroup] = []
    @Published var remove: Set<String> = []
    @Published var scanning = false
    @Published var done = false
    @Published var message: String?

    var reclaimable: Int64 { groups.flatMap { $0.items }.filter { remove.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !Demo.enabled, !scanning else { return }
        scanning = true; done = false; message = nil; groups = []; remove = []
        Task.detached { [weak self] in
            let g = SimilarFileFinder.find()
            await self?.finish(g)
        }
    }

    private func finish(_ g: [SimilarFileGroup]) {
        groups = g.sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
        remove = []                    // similar is not identical: the user decides, nothing is pre-selected
        scanning = false
        withAnimation(.spring(duration: 0.5)) { done = true }
    }

    func selectOlder() {
        var marks: Set<String> = []
        for g in groups { for f in g.items where f.id != g.newest.id { marks.insert(f.id) } }
        remove = marks
    }

    func toggle(_ f: SimilarFile) { if remove.contains(f.id) { remove.remove(f.id) } else { remove.insert(f.id) } }

    func trashMarked() {
        let targets = groups.flatMap { $0.items }.filter { remove.contains($0.id) }
        Task.detached { [weak self] in
            var freed: Int64 = 0, failed = 0
            var gone: Set<String> = []
            for t in targets { if Trasher.trash(t.url, size: t.size, kind: "Similar file") { freed += t.size; gone.insert(t.id) } else { failed += 1 } }
            await self?.afterTrash(gone, freed: freed, failed: failed)
        }
    }

    private func afterTrash(_ gone: Set<String>, freed: Int64, failed: Int) {
        withAnimation(.spring(duration: 0.4)) {
            groups = groups.compactMap { g in
                var g = g; g.items.removeAll { gone.contains($0.id) }
                return g.items.count > 1 ? g : nil
            }
            remove.subtract(gone)
            message = failed == 0 ? "Moved \(fmtFile(freed)) to Trash." : "Moved \(fmtFile(freed)); \(failed) failed."
        }
    }

    nonisolated static func find(roots: [URL]? = nil, minBytes: Int64 = 10_000) -> [SimilarFileGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanRoots = roots ?? ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0) }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var families: [String: [SimilarFile]] = [:]
        for root in scanRoots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in en {
                if f.pathComponents.contains("node_modules") { en.skipDescendants(); continue }
                guard !f.pathExtension.isEmpty, let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true,
                      v.isSymbolicLink != true, let size = v.fileSize, Int64(size) >= minBytes else { continue }
                families[FileFamily.key(for: f.lastPathComponent), default: []]
                    .append(SimilarFile(url: f, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
            }
        }
        return families.filter { $0.value.count > 1 }.map { SimilarFileGroup(id: $0.key, items: $0.value.sorted { $0.modified > $1.modified }) }
    }
}

// MARK: - Thumbnails

final class Thumbs: @unchecked Sendable {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, NSImage>()
    /// Demo mode registers generated pictures here.
    var demo: [String: NSImage] = [:]

    func cached(_ url: URL) -> NSImage? { demo[url.path] ?? cache.object(forKey: url.path as NSString) }

    func load(_ url: URL, maxPixel: Int = 220) -> NSImage? {
        if let c = cached(url) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }
}

struct PhotoThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.card)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ProgressView().controlSize(.small) }
        }
        .onAppear {
            if let c = Thumbs.shared.cached(url) { image = c; return }
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Thumbs.shared.load(url)
                DispatchQueue.main.async { image = img }
            }
        }
    }
}

// MARK: - Screens

struct SimilarPhotosView: View {
    @ObservedObject var f: SimilarPhotoFinder
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Sensitivity.allCases) { s in
                        Button { f.sensitivity = s } label: {
                            Text(s.title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                .foregroundStyle(f.sensitivity == s ? Color.white : Theme.t1)
                                .background(Capsule().fill(f.sensitivity == s ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.card)))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).disabled(f.scanning)
                Text(f.sensitivity.hint).font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                Button { f.scan() } label: {
                    Label(f.scanning ? "Comparing photos…" : "Find similar photos", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).disabled(f.scanning).padding(.horizontal, 16)
                if f.scanning { Text(f.status).font(.system(size: 10.5)).foregroundStyle(Theme.t2) }
                if let m = f.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16) }

                if f.done && f.groups.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Theme.success)
                        Text("No similar photos found").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(f.groups) { g in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(g.items.count) similar photos").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.t2)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(g.items) { p in
                                                let marked = f.remove.contains(p.id)
                                                VStack(spacing: 4) {
                                                    PhotoThumb(url: p.url).frame(width: 96, height: 96)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(marked ? Theme.danger.opacity(0.35) : .clear))
                                                        .overlay(alignment: .topLeading) {
                                                            Image(systemName: marked ? "trash.circle.fill" : "checkmark.circle.fill")
                                                                .font(.system(size: 20)).foregroundStyle(.white, marked ? Theme.danger : Theme.success).padding(5)
                                                        }
                                                        .overlay(alignment: .bottomLeading) {
                                                            if p.id == g.best.id {
                                                                Text("BEST").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                                                                    .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Theme.success)).padding(5)
                                                            }
                                                        }
                                                    Text("\(p.width)×\(p.height)").font(.system(size: 9.5, weight: .medium))
                                                    Text(fmtFile(p.size)).font(.system(size: 9.5)).foregroundStyle(Theme.t2)
                                                }
                                                .contentShape(Rectangle()).onTapGesture { f.keep(p, in: g) }
                                                .contextMenu {
                                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                                                    Button(marked ? "Keep this one too" : "Move to Trash") { f.toggle(p) }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            }
                        }.padding(.horizontal, 16)
                    }
                    if !f.groups.isEmpty {
                        Text("Tap a photo to keep it. The rest of its group goes to the Trash.").font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                        Button { confirm = true } label: {
                            Label("Move \(fmtFile(f.reclaimable)) to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
                            .disabled(f.remove.isEmpty).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirm {
                ConfirmCard(title: "Remove \(f.remove.count) similar photo(s)?",
                            message: "The photo marked BEST (or the one you picked) is kept in every group. \(fmtFile(f.reclaimable)) moves to the Trash and can be restored from History.",
                            confirm: "Move to Trash", destructive: true,
                            onConfirm: { confirm = false; f.trashMarked() }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirm)
    }
}

struct SimilarFilesView: View {
    @ObservedObject var f: SimilarFileFinder
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Text("Files that look like versions or copies of each other, such as “Report (1).pdf”, “Report copy.pdf” and “Report-2.pdf”. They are not necessarily identical, so nothing is selected for you.")
                    .font(.system(size: 11)).foregroundStyle(Theme.t2).padding(.horizontal, 16)
                Button { f.scan() } label: {
                    Label(f.scanning ? "Looking…" : "Find similar files", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).disabled(f.scanning).padding(.horizontal, 16)
                if let m = f.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16) }

                if f.done && f.groups.isEmpty {
                    Spacer(); Text("No similar files found").font(.system(size: 13, weight: .semibold)); Spacer()
                } else {
                    if !f.groups.isEmpty {
                        HStack {
                            Text("\(f.groups.count) families").font(.system(size: 11.5, weight: .semibold))
                            Spacer()
                            Button("Select older versions") { f.selectOlder() }.controlSize(.small)
                            Button("None") { f.remove = [] }.controlSize(.small)
                        }.padding(.horizontal, 16)
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(f.groups) { g in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(g.id).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.t2)
                                    ForEach(g.items) { it in
                                        let marked = f.remove.contains(it.id)
                                        HStack(spacing: 8) {
                                            Button { f.toggle(it) } label: {
                                                Image(systemName: marked ? "trash.circle.fill" : "circle")
                                                    .foregroundStyle(marked ? Theme.danger : Theme.t2).font(.system(size: 16))
                                            }.buttonStyle(.plain)
                                            VStack(alignment: .leading, spacing: 0) {
                                                HStack(spacing: 5) {
                                                    Text(it.url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
                                                    if it.id == g.newest.id { Text("NEWEST").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                                                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.success)) }
                                                }
                                                Text(it.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · " + it.modified.formatted(.relative(presentation: .named)))
                                                    .font(.system(size: 9.5)).foregroundStyle(Theme.t2).lineLimit(1)
                                            }
                                            Spacer()
                                            Text(fmtFile(it.size)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                                            Button { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } label: { Image(systemName: "magnifyingglass.circle") }
                                                .buttonStyle(.plain).help("Show in Finder")
                                        }
                                    }
                                }
                                .padding(9).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            }
                        }.padding(.horizontal, 16)
                    }
                    if !f.groups.isEmpty {
                        Button { confirm = true } label: {
                            Label("Move \(fmtFile(f.reclaimable)) to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
                            .disabled(f.remove.isEmpty).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirm {
                ConfirmCard(title: "Remove \(f.remove.count) file(s)?",
                            message: "These files are similar, not necessarily identical. Check that you do not need them. \(fmtFile(f.reclaimable)) moves to the Trash and can be restored from History.",
                            confirm: "Move to Trash", destructive: true,
                            onConfirm: { confirm = false; f.trashMarked() }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirm)
    }
}
