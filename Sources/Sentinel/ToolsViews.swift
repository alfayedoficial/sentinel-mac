import AppKit
import SwiftUI

struct ToolsTab: View {
    @ObservedObject var hub: Hub
    @Binding var tool: ToolKind?
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            if let t = tool {
                HStack(spacing: 8) {
                    Button { withAnimation(.spring(duration: 0.4)) { tool = nil } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.card))
                    }.buttonStyle(.plain)
                    Image(systemName: t.icon).foregroundStyle(t.style.solid)
                    Text(t.title).font(.system(size: 14, weight: .bold))
                    Spacer()
                }.padding(.horizontal, 16)
                Group {
                    switch t {
                    case .smart: SmartCareView(hub: hub, cleaner: hub.cleaner, disk: hub.disk, bigFiles: hub.bigFiles,
                                               startup: hub.startup, tool: $tool, tab: $tab)
                    case .uninstall: UninstallView(u: hub.uninstaller)
                    case .bigFiles: BigFilesView(f: hub.bigFiles)
                    case .duplicates: DuplicatesView(d: hub.dups)
                    case .spaceLens: SpaceLensView(l: hub.lens)
                    case .startup: StartupView(m: hub.startup)
                    case .maintenance: MaintenanceView()
                    case .history: HistoryView()
                    case .threats: ThreatWatchView()
                    case .similarPhotos: SimilarPhotosView(f: hub.photos)
                    case .similarFiles: SimilarFilesView(f: hub.similarFiles)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tools").font(.system(size: 13, weight: .semibold))
                        Button { withAnimation(.spring(duration: 0.4)) { tool = .smart } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "wand.and.stars").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Smart Care").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                    Text("Scan caches, Trash, big files, startup items and idle apps in one go")
                                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(14).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.brandGradient))
                        }.buttonStyle(.plain)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(ToolKind.allCases.filter { $0 != .smart }) { t in
                                QuickAction(icon: t.icon, title: t.title, sub: t.blurb, tint: t.style) {
                                    withAnimation(.spring(duration: 0.4)) { tool = t }
                                }
                            }
                        }
                    }.padding(.horizontal, 16)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: tool)
    }
}

// MARK: - Smart Care

struct SmartCareView: View {
    @ObservedObject var hub: Hub
    @ObservedObject var cleaner: CacheCleaner
    @ObservedObject var disk: DiskStats
    @ObservedObject var bigFiles: BigFileFinder
    @ObservedObject var startup: StartupManager
    @ObservedObject private var monitor = Monitor.shared
    @Binding var tool: ToolKind?
    @Binding var tab: Tab
    @State private var started = Demo.enabled
    @State private var confirmClean = false
    @State private var confirmTrash = false
    @State private var spin = false

    private var scanning: Bool { cleaner.state == .scanning || bigFiles.scanning || startup.loading }
    private var finished: Bool { started && !scanning && cleaner.state != .idle && bigFiles.done && startup.loaded }
    private var bigBytes: Int64 { bigFiles.files.reduce(0) { $0 + $1.size } }
    private var reclaim: Int64 { cleaner.selectedBytes + disk.trash }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    if started {
                        VStack(spacing: 8) {
                            ResultRow(icon: "sparkles", tint: .clean, title: "System junk",
                                      detail: cleaner.state == .scanning ? "Scanning…" : "\(cleaner.items.count) caches unused for 1 month+",
                                      value: cleaner.state == .scanning ? nil : fmtFile(cleaner.selectedBytes), action: "Review") {
                                withAnimation { tab = .clean }
                            }
                            ResultRow(icon: "trash.fill", tint: .trash, title: "Trash", detail: "Waiting to be emptied",
                                      value: fmtFile(disk.trash), action: "Empty") { confirmTrash = true }
                            ResultRow(icon: "doc.zipper", tint: .bigFiles, title: "Big old files",
                                      detail: bigFiles.scanning ? "Scanning…" : "\(bigFiles.files.count) files over 500 MB, unused 3 months+",
                                      value: bigFiles.scanning ? nil : fmtFile(bigBytes), action: "Review") {
                                withAnimation { tool = .bigFiles }
                            }
                            ResultRow(icon: "power.circle.fill", tint: .startup, title: "Startup items",
                                      detail: startup.loading ? "Scanning…"
                                          : "\(startup.items.count) items" + (startup.brokenCount > 0 ? " · \(startup.brokenCount) broken leftovers" : ""),
                                      value: nil, action: "Review") { withAnimation { tool = .startup } }
                            ResultRow(icon: "bolt.badge.clock.fill", tint: .remove, title: "Idle apps",
                                      detail: monitor.flagged.isEmpty ? "None found" : monitor.flagged.map { $0.name }.prefix(3).joined(separator: ", "),
                                      value: monitor.flagged.isEmpty ? nil : fmtBytes(monitor.flagged.reduce(0) { $0 + $1.footprint }),
                                      action: "Review") { withAnimation { tab = .background } }
                        }.transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            if confirmClean {
                ConfirmCard(title: "Clean safe caches?",
                            message: "\(fmtFile(cleaner.selectedBytes)) of caches unused for a month or more will move to the Trash. Items for running apps are skipped.",
                            confirm: "Clean", onConfirm: { confirmClean = false; cleaner.permanent = false; cleaner.clean() },
                            onCancel: { confirmClean = false })
            }
            if confirmTrash {
                ConfirmCard(title: "Empty the Trash?", message: "\(fmtFile(disk.trash)) will be permanently deleted.",
                            confirm: "Empty Trash", destructive: true,
                            onConfirm: { confirmTrash = false; disk.emptyTrash() }, onCancel: { confirmTrash = false })
            }
        }
        .animation(.spring(duration: 0.4), value: started)
        .animation(.spring(duration: 0.35), value: confirmClean)
        .animation(.spring(duration: 0.35), value: confirmTrash)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(Color.brandA.opacity(0.18 - Double(i) * 0.05), lineWidth: 2)
                        .frame(width: 110 + CGFloat(i) * 26, height: 110 + CGFloat(i) * 26)
                        .scaleEffect(scanning && spin ? 1.08 : 1)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: spin)
                }
                Circle().fill(Color.brandGradient).frame(width: 104, height: 104).shadow(color: .brandA.opacity(0.4), radius: 14)
                if scanning {
                    ProgressView().controlSize(.large).tint(.white)
                } else if finished {
                    VStack(spacing: 0) {
                        Text(fmtFile(reclaim)).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.6)
                        Text("can be freed").font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                    }
                } else {
                    Image(systemName: "wand.and.stars").font(.system(size: 36)).foregroundStyle(.white)
                }
            }
            .frame(height: 170)
            Text(scanning ? "Scanning your Mac…" : finished ? "Scan complete" : "Check everything in one tap")
                .font(.system(size: 14, weight: .semibold)).contentTransition(.opacity)
            HStack(spacing: 8) {
                Button { startScan() } label: {
                    Label(started ? "Scan again" : "Scan", systemImage: "magnifyingglass").frame(width: 120)
                }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.large).disabled(scanning)
                if finished && cleaner.selectedBytes > 0 {
                    Button { confirmClean = true } label: { Label("Clean junk", systemImage: "sparkles").frame(width: 110) }
                        .buttonStyle(.bordered).controlSize(.large).transition(.scale.combined(with: .opacity))
                }
            }
        }
        .onAppear { spin = true }
    }

    private func startScan() {
        started = true
        cleaner.range = .month
        cleaner.scan()
        bigFiles.minMB = 500
        bigFiles.range = .threeMonths
        bigFiles.scan()
        startup.load()
        disk.refresh()
    }
}

struct ResultRow: View {
    let icon: String
    let tint: TileStyle
    let title: String
    let detail: String
    let value: String?
    let action: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.t2).lineLimit(2)
            }
            Spacer()
            if let value { Text(value).font(.system(size: 12, weight: .bold)).monospacedDigit() }
            else { ProgressView().controlSize(.mini).opacity(detail == "Scanning…" ? 1 : 0) }
            Button(action, action: onTap).controlSize(.small).buttonStyle(.bordered)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

// MARK: - Startup Manager

struct StartupView: View {
    @ObservedObject var m: StartupManager
    @State private var pending: StartupItem?

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Text("Items that start with your Mac or run in the background. Broken ones point to apps that no longer exist.")
                    .font(.system(size: 11)).foregroundStyle(Theme.t2).padding(.horizontal, 16)
                if let msg = m.message { Text(msg).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16) }
                if m.loading && m.items.isEmpty {
                    Spacer(); ProgressView(); Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(m.items) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.broken ? "exclamationmark.triangle.fill" : item.running ? "play.circle.fill" : "pause.circle")
                                        .foregroundStyle(item.broken ? Theme.warning : item.running ? Theme.success : .secondary)
                                        .font(.system(size: 17))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.suspicious.map { "Suspicious: " + $0 } ?? (item.broken ? "Broken — its program was removed" : item.kind.rawValue + (item.running ? " · running" : "")))
                                            .font(.system(size: 10)).foregroundStyle(item.suspicious != nil ? Theme.danger : item.broken ? Theme.warning : Theme.t2)
                                    }
                                    Spacer()
                                    Button(item.broken ? "Remove" : "Turn off") { pending = item }
                                        .controlSize(.small).buttonStyle(.bordered)
                                }
                                .padding(9).background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(item.broken ? Theme.warning.opacity(0.1) : Theme.card))
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if let p = pending {
                ConfirmCard(title: "\(p.broken ? "Remove" : "Turn off") \(p.name)?",
                            message: p.kind.needsAdmin
                                ? "This is a system-wide item, so macOS will ask for your administrator password. The file is moved to /Library/SentinelDisabled, not erased."
                                : "It will stop running and its file moves to the Trash. You can restore it from there.",
                            confirm: p.broken ? "Remove" : "Turn off", destructive: true,
                            onConfirm: { m.disable(p); pending = nil }, onCancel: { pending = nil })
            }
        }
        .animation(.spring(duration: 0.35), value: pending)
        .onAppear { if !m.loaded { m.load() } }
    }
}

// MARK: - Space Lens

struct SpaceLensView: View {
    @ObservedObject var l: SpaceLens
    @State private var pending: LensEntry?

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(l.stack.enumerated()), id: \.offset) { i, u in
                            Button { l.jump(to: i) } label: {
                                Text(i == 0 ? "Home" : u.lastPathComponent).font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(i == l.stack.count - 1 ? Color.brandA.opacity(0.2) : Theme.card))
                            }.buttonStyle(.plain)
                            if i < l.stack.count - 1 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.t2.opacity(0.6)) }
                        }
                    }.padding(.horizontal, 16)
                }
                if let m = l.message { Text(m).font(.system(size: 11)).foregroundStyle(Theme.success).padding(.horizontal, 16) }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(l.entries) { e in
                            HStack(spacing: 8) {
                                Image(nsImage: IconCache.shared.icon(for: e.url.path)).resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
                                    if let s = e.size { UsageBar(value: Double(s) / Double(l.maxSize), color: e.isDir ? Theme.accent : TileStyle.bigFiles.solid) }
                                    else { Capsule().fill(Theme.card).frame(height: 7) }
                                }
                                if let s = e.size { Text(fmtFile(s)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 62, alignment: .trailing) }
                                else { ProgressView().controlSize(.mini).frame(width: 62) }
                                if e.isDir { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.t2.opacity(0.6)) }
                            }
                            .padding(7).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            .contentShape(Rectangle())
                            .onTapGesture { l.open(e) }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
                                Button("Move to Trash…", role: .destructive) { pending = e }
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
                Text("Click a folder to look inside · right-click for Finder or Trash")
                    .font(.system(size: 10)).foregroundStyle(Theme.t2).padding(.bottom, 4)
            }
            if let p = pending {
                ConfirmCard(title: "Move \(p.url.lastPathComponent) to Trash?",
                            message: "\(p.size.map(fmtFile) ?? "This item") will be moved to the Trash.", confirm: "Move to Trash", destructive: true,
                            onConfirm: { l.trash(p); pending = nil }, onCancel: { pending = nil })
            }
        }
        .animation(.spring(duration: 0.4), value: l.entries.count)
        .animation(.spring(duration: 0.35), value: pending)
        .onAppear { if l.entries.isEmpty { l.load() } }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @ObservedObject var d: DuplicateFinder
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack {
                    Text("Files bigger than").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    Picker("", selection: $d.minMB) {
                        Text("1 MB").tag(1.0); Text("5 MB").tag(5.0); Text("50 MB").tag(50.0); Text("200 MB").tag(200.0)
                    }.labelsHidden().frame(width: 90)
                    Spacer()
                }.padding(.horizontal, 16)
                Button { d.scan() } label: {
                    Label(d.scanning ? "Comparing files…" : "Find duplicates", systemImage: "square.on.square").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).disabled(d.scanning).padding(.horizontal, 16)
                if d.scanning { Text(d.status).font(.system(size: 10.5)).foregroundStyle(Theme.t2) }
                if let m = d.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16) }

                if d.done && d.groups.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Theme.success)
                        Text("No duplicates found").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(d.groups) { g in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(g.files.count) identical copies · \(fmtFile(g.size)) each")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.t2)
                                    ForEach(g.files) { f in
                                        let marked = d.remove.contains(f.id)
                                        HStack(spacing: 8) {
                                            Button { d.toggle(f) } label: {
                                                Image(systemName: marked ? "trash.circle.fill" : "checkmark.circle.fill")
                                                    .foregroundStyle(marked ? Theme.danger : Theme.success).font(.system(size: 16))
                                                    .contentTransition(.symbolEffect(.replace))
                                            }.buttonStyle(.plain)
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(f.url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
                                                Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                    .font(.system(size: 9.5)).foregroundStyle(Theme.t2).lineLimit(1)
                                            }
                                            Spacer()
                                            Text(marked ? "Remove" : "Keep").font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(marked ? Theme.danger : Theme.success)
                                            Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: {
                                                Image(systemName: "magnifyingglass.circle")
                                            }.buttonStyle(.plain).help("Show in Finder")
                                        }
                                        .contentShape(Rectangle()).onTapGesture { d.keep(f, in: g) }
                                    }
                                }
                                .padding(9).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            }
                        }.padding(.horizontal, 16)
                    }
                    if !d.groups.isEmpty {
                        Button { confirm = true } label: {
                            Label("Move \(fmtFile(d.reclaimable)) to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
                            .disabled(d.remove.isEmpty).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirm {
                ConfirmCard(title: "Remove \(d.remove.count) duplicate(s)?",
                            message: "One copy of every file is kept. \(fmtFile(d.reclaimable)) moves to the Trash. Tap a file to choose which copy to keep.",
                            confirm: "Move to Trash", destructive: true,
                            onConfirm: { confirm = false; d.trashMarked() }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirm)
    }
}
