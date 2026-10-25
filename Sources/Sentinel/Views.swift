import AppKit
import ServiceManagement
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Overview", background = "Apps", clean = "Clean", tools = "Tools", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .background: "square.stack.3d.up.fill"
        case .clean: "sparkles"
        case .tools: "wrench.and.screwdriver.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainView: View {
    @ObservedObject private var monitor = Monitor.shared
    @ObservedObject private var hub = Hub.shared
    @State private var tab: Tab
    @State private var tool: ToolKind?
    @Namespace private var ns

    init(tab: Tab = .overview, tool: ToolKind? = nil) {
        _tab = State(initialValue: tab)
        _tool = State(initialValue: tool)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch tab {
                case .overview: OverviewTab(tab: $tab, tool: $tool, cleaner: hub.cleaner, disk: hub.disk)
                case .background: BackgroundTab()
                case .clean: CleanTab(cleaner: hub.cleaner)
                case .tools: ToolsTab(hub: hub, tool: $tool, tab: $tab)
                case .settings: SettingsTab()
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
        .frame(width: 400, height: 580)
        .background(Theme.win)
        .onAppear { hub.disk.refresh(); Monitor.shared.uiVisible = true }
        .onDisappear { Monitor.shared.uiVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoTile(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sentinel").font(.system(size: 15, weight: .bold))
                Text(monitor.flagged.isEmpty ? "Everything looks good" : "\(monitor.flagged.count) app(s) could be stopped")
                    .font(.system(size: 11)).foregroundStyle(monitor.flagged.isEmpty ? Theme.t2 : Theme.warning)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Theme.t2).help("Quit Sentinel")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 15, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(tab == t ? Color.white : Theme.t2)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background {
                        if tab == t {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.brandGradient)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Theme.card)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @ObservedObject private var monitor = Monitor.shared
    @Binding var tab: Tab
    @Binding var tool: ToolKind?
    @ObservedObject var cleaner: CacheCleaner
    @ObservedObject var disk: DiskStats
    @State private var confirmEmpty = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 14) {
                    UpdateBanner()
                    Button { withAnimation(.spring) { tool = .smart; tab = .tools } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wand.and.stars").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Smart Care").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                Text("Scan caches, Trash, big files, startup and idle apps").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85))
                            }
                            Spacer()
                            Text("Scan").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentDeep)
                                .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(.white))
                        }
                        .padding(12).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.brandGradient))
                    }.buttonStyle(.plain)
                    HStack(spacing: 8) {
                        RingGauge(value: monitor.memory.fraction, title: "Memory", color: monitor.memory.pressure >= 2 ? monitor.memory.pressureColor : nil,
                                  center: "\(monitor.memory.percent)%", sub: monitor.memory.pressureLabel, icon: "memorychip")
                        RingGauge(value: monitor.battery.hasBattery ? monitor.battery.fraction : 1,
                                  title: "Battery", color: monitor.battery.hasBattery && !monitor.battery.onAC && monitor.battery.percent <= 40 ? monitor.battery.color : nil,
                                  center: monitor.battery.hasBattery ? "\(monitor.battery.percent)%" : "AC",
                                  sub: monitor.battery.statusLabel, icon: monitor.battery.charging ? "bolt.fill" : "battery.75percent")
                        RingGauge(value: disk.usedFraction, title: "Disk", color: disk.usedFraction > 0.9 ? Theme.danger : nil,
                                  center: fmtFile(disk.free), sub: "free", icon: "internaldrive")
                    }

                    if !monitor.flagged.isEmpty {
                        Button { withAnimation(.spring) { tab = .background } } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(monitor.flagged.count) unused app(s) found").font(.system(size: 13, weight: .semibold))
                                    Text("Stopping them frees \(fmtBytes(monitor.flagged.reduce(0) { $0 + $1.footprint }))")
                                        .font(.system(size: 11)).foregroundStyle(Theme.t2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.t2.opacity(0.6))
                            }
                            .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.12)))
                        }.buttonStyle(.plain).transition(.scale.combined(with: .opacity))
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        QuickAction(icon: "sparkles", title: "Quick Clean", sub: "Caches unused 1 month+", tint: .clean) {
                            cleaner.range = .month
                            withAnimation(.spring) { tab = .clean }
                            cleaner.scan()
                        }
                        QuickAction(icon: "trash.slash.fill", title: "Empty Trash", sub: disk.emptying ? "Emptying…" : fmtFile(disk.trash), tint: .trash) {
                            confirmEmpty = true
                        }
                        QuickAction(icon: "xmark.app.fill", title: "Remove Apps", sub: "With all their data", tint: .remove) {
                            withAnimation(.spring) { tool = .uninstall; tab = .tools }
                        }
                        QuickAction(icon: "power.circle.fill", title: "Startup Items", sub: "Login items & helpers", tint: .startup) {
                            withAnimation(.spring) { tool = .startup; tab = .tools }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top memory users").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.t2)
                        let top = Array(monitor.apps.prefix(5))
                        let maxMem = Double(top.first?.footprint ?? 1)
                        ForEach(top) { app in
                            HStack(spacing: 8) {
                                Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                                Text(app.name).font(.system(size: 12)).lineLimit(1).frame(width: 110, alignment: .leading)
                                UsageBar(value: Double(app.footprint) / maxMem, color: .brandA)
                                Text(fmtBytes(app.footprint)).font(.system(size: 11)).monospacedDigit()
                                    .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                .animation(.spring(duration: 0.5), value: monitor.flagged.count)
            }
            if confirmEmpty {
                ConfirmCard(title: "Empty the Trash?", message: "\(fmtFile(disk.trash)) will be permanently deleted. This can't be undone.",
                            confirm: "Empty Trash", destructive: true,
                            onConfirm: { disk.emptyTrash(); confirmEmpty = false },
                            onCancel: { confirmEmpty = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirmEmpty)
    }
}

struct RingGauge: View {
    let value: Double
    let title: String
    let color: Color?
    let center: String
    let sub: String
    let icon: String
    @State private var shown: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 9)
                Circle().trim(from: 0, to: shown)
                    .stroke(color.map { AnyShapeStyle(AngularGradient(colors: [$0.opacity(0.5), $0], center: .center)) }
                                ?? AnyShapeStyle(Theme.ring),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color ?? Theme.link)
                    Text(center).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.t1).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(.numericText())
                }.padding(.horizontal, 6)
            }
            .frame(width: 84, height: 84)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(sub).font(.system(size: 10)).foregroundStyle(Theme.t2).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(duration: 1.0)) { shown = value } }
        .onChange(of: value) { _, v in withAnimation(.spring(duration: 0.8)) { shown = v } }
    }
}

struct UsageBar: View {
    let value: Double
    let color: Color
    @State private var shown: Double = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule().fill(color.gradient).frame(width: max(4, g.size.width * shown))
            }
        }
        .frame(height: 7)
        .onAppear { withAnimation(.spring(duration: 0.8)) { shown = value } }
        .onChange(of: value) { _, v in withAnimation(.spring(duration: 0.6)) { shown = v } }
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    let sub: String
    let tint: TileStyle
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(sub).font(.system(size: 10)).foregroundStyle(Theme.t2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
            .scaleEffect(hover ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct ConfirmCard: View {
    let title: String
    let message: String
    let confirm: String
    var destructive = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(spacing: 12) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(destructive ? Theme.danger : Color.brandA)
                Text(title).font(.system(size: 15, weight: .bold))
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.t2).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered)
                    Button(confirm, action: onConfirm).buttonStyle(.borderedProminent).tint(destructive ? Theme.danger : .brandA)
                }
            }
            .padding(20).frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 20)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .transition(.opacity)
    }
}

// MARK: - Apps in the background

struct BackgroundTab: View {
    @ObservedObject private var monitor = Monitor.shared
    @State private var confirmAll = false

    var body: some View {
        ZStack {
        VStack(alignment: .leading, spacing: 10) {
            let flaggedIDs = Set(monitor.flagged.map { $0.id })
            let list = monitor.apps.filter { !$0.isFrontmost }
                .sorted { (flaggedIDs.contains($0.id) ? 1 : 0, $0.footprint) > (flaggedIDs.contains($1.id) ? 1 : 0, $1.footprint) }
            HStack {
                Text("Apps running in the background").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !monitor.flagged.isEmpty {
                    Button { confirmAll = true } label: { Label("Quit \(monitor.flagged.count) unused", systemImage: "power") }
                        .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.small)
                        .transition(.scale.combined(with: .opacity))
                }
            }.padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(list) { app in
                        let flag = monitor.flagged.first { $0.id == app.id }
                        BackgroundRow(app: app, flag: flag)
                            .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .animation(.spring(duration: 0.45), value: list.map { $0.id })
            }
        }
        if confirmAll {
            ConfirmCard(title: "Quit \(monitor.flagged.count) unused app(s)?",
                        message: monitor.flagged.map { $0.name }.prefix(4).joined(separator: ", ")
                            + (monitor.flagged.count > 4 ? " and more" : "")
                            + " will be asked to quit, so you can still save open work. This frees about \(fmtBytes(monitor.flagged.reduce(0) { $0 + $1.footprint })).",
                        confirm: "Quit apps",
                        onConfirm: { for f in monitor.flagged { Monitor.shared.stop(f.id) }; confirmAll = false },
                        onCancel: { confirmAll = false })
        }
        }
        .animation(.spring(duration: 0.35), value: confirmAll)
    }
}

struct BackgroundRow: View {
    let app: AppUsage
    let flag: FlaggedApp?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if flag != nil {
                            Text("Unused").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.warning))
                        }
                    }
                    Text(app.hasWindow ? "Window open · idle \(fmtDuration(app.idle))" : "No window · idle \(fmtDuration(app.idle))")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(fmtBytes(app.footprint)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    Text("\(Int(app.cpu))% CPU").font(.system(size: 10)).foregroundStyle(Theme.t2).monospacedDigit()
                }
                Menu {
                    Button("Quit") { Monitor.shared.stop(app.id) }
                    Button("Force quit", role: .destructive) { Monitor.shared.stop(app.id, force: true) }
                    Divider()
                    Button("Never suggest this app") { Monitor.shared.ignoreForever(bundleID: app.bundleID, id: app.id) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let flag {
                ForEach(flag.reasons, id: \.self) { r in
                    Text(r).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                Button { Monitor.shared.stop(app.id) } label: { Label("Quit \(app.name)", systemImage: "power") }
                    .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(flag != nil ? Theme.warning.opacity(0.1) : Theme.card))
    }
}

// MARK: - Cache cleaner

struct CleanTab: View {
    @ObservedObject var cleaner: CacheCleaner
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Clean caches").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16)
                Text("Find caches and logs not touched for at least…").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    .padding(.horizontal, 16)
                RangePicker(range: $cleaner.range).padding(.horizontal, 16)
                    .disabled(cleaner.state == .scanning || cleaner.state == .cleaning)

                switch cleaner.state {
                case .idle:
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(Color.brandGradient)
                        Text("Scan first, then review before anything is removed.")
                            .font(.system(size: 12)).foregroundStyle(Theme.t2).multilineTextAlignment(.center)
                        Button { cleaner.scan() } label: { Label("Scan caches", systemImage: "magnifyingglass").frame(width: 180) }
                            .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.large)
                    }.frame(maxWidth: .infinity)
                    Spacer()
                case .scanning, .cleaning:
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(cleaner.state == .scanning ? "Scanning… \(cleaner.scannedFolders) folders" : "Moving items to Trash…")
                            .font(.system(size: 12, weight: .medium))
                        if cleaner.state == .scanning {
                            Text(cleaner.currentFolder).font(.system(size: 10)).foregroundStyle(Theme.t2).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity)
                    Spacer()
                case .report:
                    ReportView(cleaner: cleaner, onClean: { confirm = true })
                case .done(let freed, let failed):
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 46)).foregroundStyle(Theme.success)
                            .symbolEffect(.bounce, value: freed)
                        Text(fmtFile(freed) + " moved to Trash").font(.system(size: 15, weight: .bold))
                        Text(failed == 0 ? "Empty the Trash from the Overview tab to free the space."
                                         : "\(failed) item(s) could not be removed.")
                            .font(.system(size: 12)).foregroundStyle(Theme.t2).multilineTextAlignment(.center)
                        Button("Done") { cleaner.reset() }.buttonStyle(.borderedProminent).tint(Theme.accentDeep)
                    }.frame(maxWidth: .infinity).padding(.horizontal, 20)
                    Spacer()
                }
            }
            if confirm {
                ConfirmCard(
                    title: "Clean \(cleaner.selected.count) item(s)?",
                    message: "\(fmtFile(cleaner.selectedBytes)) of caches unused for \(cleaner.range.title.lowercased()) or more will be "
                        + (cleaner.permanent ? "permanently deleted." : "moved to the Trash."),
                    confirm: cleaner.permanent ? "Delete" : "Move to Trash", destructive: cleaner.permanent,
                    onConfirm: { confirm = false; cleaner.clean() }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.4), value: cleaner.state)
        .animation(.spring(duration: 0.35), value: confirm)
    }
}

struct RangePicker: View {
    @Binding var range: CleanRange
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 4) {
            ForEach(CleanRange.allCases) { r in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { range = r } } label: {
                    Text(r.title.replacingOccurrences(of: "1 ", with: "")).font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(range == r ? Color.white : Color.primary)
                        .contentShape(Capsule())
                        .background {
                            if range == r { Capsule().fill(Color.brandGradient).matchedGeometryEffect(id: "r", in: ns) }
                        }
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Capsule().fill(Theme.card))
    }
}

struct ReportView: View {
    @ObservedObject var cleaner: CacheCleaner
    let onClean: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(cleaner.items.count) items · \(fmtFile(cleaner.totalBytes))").font(.system(size: 12, weight: .semibold))
                    Text("Not used for \(cleaner.range.title.lowercased()) or more").font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                }
                Spacer()
                Button("Select all") { cleaner.setAll(true) }.controlSize(.small)
                Button("None") { cleaner.setAll(false) }.controlSize(.small)
            }.padding(.horizontal, 16)

            if cleaner.items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 36)).foregroundStyle(Theme.success)
                    Text("Nothing old enough to clean.").font(.system(size: 13, weight: .semibold))
                    Text("Try a shorter time range.").font(.system(size: 11)).foregroundStyle(Theme.t2)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                        ForEach(cleaner.grouped, id: \.0) { cat, items in
                            Text(cat.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.t2)
                                .padding(.top, 6)
                            ForEach(items) { item in CacheRow(item: item, on: cleaner.selected.contains(item.id)) { cleaner.toggle(item) } }
                        }
                    }.padding(.horizontal, 16)
                }
                VStack(spacing: 6) {
                    Toggle("Delete permanently (skip Trash)", isOn: $cleaner.permanent).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                    Button(action: onClean) {
                        Label("Clean \(fmtFile(cleaner.selectedBytes))", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.large).disabled(cleaner.selected.isEmpty)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

struct CacheRow: View {
    let item: CacheItem
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.brandA : Theme.t2).font(.system(size: 16))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("Last used " + item.lastModified.formatted(.relative(presentation: .named)))
                        if item.inUse { Text("· app running").foregroundStyle(Theme.warning) }
                        if item.isSystem { Text("· system").foregroundStyle(Theme.warning) }
                    }.font(.system(size: 10)).foregroundStyle(Theme.t2)
                }
                Spacer()
                Text(fmtFile(item.size)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        }.buttonStyle(.plain)
    }
}

// MARK: - Remove apps and big files

struct UninstallView: View {
    @ObservedObject var u: Uninstaller
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.t2)
                    TextField("Search apps", text: $u.search).textFieldStyle(.plain)
                    if u.loading { ProgressView().controlSize(.small) }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .padding(.horizontal, 16)

                if let m = u.message {
                    Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let sel = u.selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(nsImage: IconCache.shared.icon(for: sel.url.path)).resizable().frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(sel.name).font(.system(size: 14, weight: .bold))
                                Text("App \(fmtFile(sel.size))" + (u.leftovers.isEmpty ? "" : " · data \(fmtFile(u.leftoverBytes))"))
                                    .font(.system(size: 11)).foregroundStyle(Theme.t2)
                            }
                            Spacer()
                            Button { u.select(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.t2.opacity(0.6))
                        }
                        Toggle("Also remove its data, caches and history", isOn: $u.removeData).font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(u.leftovers) { l in
                                    HStack {
                                        Image(systemName: "doc.fill").font(.system(size: 10)).foregroundStyle(Theme.t2)
                                        Text(l.url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                        Text(fmtFile(l.size)).font(.system(size: 10.5)).foregroundStyle(Theme.t2).monospacedDigit()
                                    }
                                    .opacity(u.removeData ? 1 : 0.4)
                                }
                                if u.leftovers.isEmpty { Text("No leftover data found.").font(.system(size: 11)).foregroundStyle(Theme.t2) }
                            }
                        }.frame(maxHeight: 220)
                        Button { confirm = true } label: {
                            Label(u.busy ? "Removing…" : "Uninstall \(sel.name)", systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large).disabled(u.busy)
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                    .padding(.horizontal, 16).transition(.scale(scale: 0.95).combined(with: .opacity))
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(u.filtered) { app in
                                Button { withAnimation(.spring(duration: 0.4)) { u.select(app) } } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: IconCache.shared.icon(for: app.url.path)).resizable().frame(width: 28, height: 28)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                            Text(app.url.deletingLastPathComponent().path).font(.system(size: 9.5)).foregroundStyle(Theme.t2).lineLimit(1)
                                        }
                                        Spacer()
                                        if app.size == 0 { ProgressView().controlSize(.mini) }
                                        else { Text(fmtFile(app.size)).font(.system(size: 11.5, weight: .medium)).monospacedDigit() }
                                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.t2.opacity(0.6))
                                    }
                                    .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirm, let sel = u.selected {
                ConfirmCard(title: "Uninstall \(sel.name)?",
                            message: "The app" + (u.removeData ? " and \(u.leftovers.count) data item(s)" : "") + " will move to the Trash. "
                                + "\(fmtFile(sel.size + (u.removeData ? u.leftoverBytes : 0))) in total. If it is running it will be quit first.",
                            confirm: "Move to Trash", destructive: true,
                            onConfirm: { confirm = false; u.uninstall(sel) }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirm)
        .onAppear { u.load() }
    }
}

struct BigFilesView: View {
    @ObservedObject var f: BigFileFinder
    @State private var confirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                HStack {
                    Text("Bigger than").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    Picker("", selection: $f.minMB) {
                        Text("100 MB").tag(100.0); Text("200 MB").tag(200.0); Text("500 MB").tag(500.0); Text("1 GB").tag(1024.0)
                    }.labelsHidden().frame(width: 90)
                    Text("and unused for").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    Picker("", selection: $f.range) { ForEach(CleanRange.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 100)
                }.padding(.horizontal, 16)
                Button { f.scan() } label: {
                    Label(f.scanning ? "Scanning…" : "Find big old files", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accentDeep).disabled(f.scanning).padding(.horizontal, 16)

                if let m = f.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.success).padding(.horizontal, 16) }

                if f.done && f.files.isEmpty {
                    Spacer(); Text("No matching files found.").font(.system(size: 12)).foregroundStyle(Theme.t2); Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(f.files) { file in
                                HStack(spacing: 8) {
                                    Button { f.toggle(file) } label: {
                                        Image(systemName: f.selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(f.selected.contains(file.id) ? Color.brandA : Theme.t2)
                                    }.buttonStyle(.plain)
                                    Image(nsImage: IconCache.shared.icon(for: file.url.path)).resizable().frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(file.url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
                                        Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.system(size: 9.5)).foregroundStyle(Theme.t2).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(fmtFile(file.size)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                                        Image(systemName: "magnifyingglass.circle")
                                    }.buttonStyle(.plain).help("Show in Finder")
                                }
                                .padding(7).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            }
                        }.padding(.horizontal, 16)
                    }
                    if !f.files.isEmpty {
                        Button { confirm = true } label: {
                            Label("Move \(fmtFile(f.selectedBytes)) to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
                            .disabled(f.selected.isEmpty).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            if confirm {
                ConfirmCard(title: "Move \(f.selected.count) file(s) to Trash?",
                            message: "\(fmtFile(f.selectedBytes)) will move to the Trash. Review the list first — these are your own files.",
                            confirm: "Move to Trash", destructive: true,
                            onConfirm: { confirm = false; f.trashSelected() }, onCancel: { confirm = false })
            }
        }
        .animation(.spring(duration: 0.35), value: confirm)
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @AppStorage("popupEnabled") private var popups = true
    @AppStorage("weeklyReminder") private var weekly = false
    @AppStorage("idleMinutes") private var idle = 20.0
    @AppStorage("memThresholdMB") private var mem = 300.0
    @AppStorage("cpuThreshold") private var cpu = 15.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject private var monitor = Monitor.shared
    @State private var showAbout = false

    var body: some View {
        Group {
            if showAbout { AboutView { withAnimation(.spring(duration: 0.35)) { showAbout = false } } }
            else { settingsList.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.35), value: showAbout)
    }

    private var settingsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    Toggle("Show popup when an app looks unused", isOn: $popups).toggleStyle(CheckToggleStyle())
                    Toggle("Remind me weekly to clean old caches", isOn: Binding(get: { weekly }, set: { on in
                        weekly = on
                        if on { WeeklyCheck.requestPermission(); WeeklyCheck.shared.start() }
                    })).toggleStyle(CheckToggleStyle())
                    Toggle("Open Sentinel at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                        launchAtLogin = on
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    })).toggleStyle(CheckToggleStyle())
                }
                UpdatesCard()
                Card {
                    Text("When is an app “unused”?").font(.system(size: 12, weight: .semibold))
                    SliderRow(title: "Idle for", value: $idle, range: 5...120, step: 5, unit: "min")
                    SliderRow(title: "Memory above", value: $mem, range: 100...2000, step: 50, unit: "MB")
                    SliderRow(title: "Background CPU above", value: $cpu, range: 5...80, step: 5, unit: "%")
                    Text("Apps playing audio, downloading or keeping the Mac awake are never flagged.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.t2)
                }
                Card {
                    Text("Ignored apps").font(.system(size: 12, weight: .semibold))
                    if monitor.ignoredIDs.isEmpty {
                        Text("None").font(.system(size: 11)).foregroundStyle(Theme.t2)
                    }
                    ForEach(monitor.ignoredIDs, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button("Remove") { monitor.unignore(id) }.controlSize(.small)
                        }
                    }
                }
                Button { withAnimation(.spring(duration: 0.35)) { showAbout = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "info").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.brand))
                        Text("About Sentinel").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.t1)
                        Spacer()
                        Text(AppInfo.version).font(.system(size: 12)).foregroundStyle(Theme.t2)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.t2)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .font(.system(size: 12))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11.5))
                Spacer()
                Text("\(Int(value)) \(unit)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step).controlSize(.small).tint(Theme.slider)
        }
    }
}

// MARK: - About

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
}

struct AboutView: View {
    var onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Settings").font(.system(size: 12.5, weight: .semibold))
                    }.foregroundStyle(Theme.link).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 5) {
                    LogoTile(size: 84)
                    Text("Sentinel").font(.system(size: 20, weight: .bold))
                    Text("Version \(AppInfo.version) (\(AppInfo.build))").font(.system(size: 12.5)).foregroundStyle(Theme.t2)
                    Text("Watches memory, battery and disk, finds apps you aren’t using, and cleans old caches.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.t2).multilineTextAlignment(.center).frame(maxWidth: 280)
                }.padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("MADE BY").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.t2)
                    HStack(spacing: 12) {
                        Text("AF").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.iconTile))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0x2A4EBC), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("AF.APPS").font(.system(size: 15, weight: .bold))
                            Text("Software studio").font(.system(size: 11.5)).foregroundStyle(Theme.t2)
                        }
                        Spacer()
                    }
                    Link(destination: URL(string: "https://afapps.4fdev.com")!) {
                        HStack {
                            Text("AFApps Website").font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(Theme.brand))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))

                VStack(spacing: 0) {
                    ForEach(Array([("Version", AppInfo.version), ("Build", AppInfo.build), ("Requires", "macOS 14 or later")].enumerated()), id: \.offset) { i, f in
                        HStack { Text(f.0); Spacer(); Text(f.1).foregroundStyle(Theme.t2) }
                            .font(.system(size: 12.5)).frame(minHeight: 34)
                        if i < 2 { Divider().overlay(Theme.track) }
                    }
                }
                .padding(.horizontal, 14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))

                Text("© 2026 AF.APPS. All rights reserved.").font(.system(size: 10.5)).foregroundStyle(Theme.t2)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}
