import AppKit
import Combine
import SwiftUI

final class AlertModel: ObservableObject {
    @Published var items: [FlaggedApp] = []
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The animated popup that slides in at the top-right of the screen.
@MainActor
final class AlertPresenter {
    static let shared = AlertPresenter()

    private let model = AlertModel()
    private var panel: FloatingPanel?
    private var host: NSHostingView<AlertView>?
    private var bag = Set<AnyCancellable>()

    func show(_ new: [FlaggedApp]) {
        for n in new where !model.items.contains(where: { $0.id == n.id }) {
            withAnimation(.spring(duration: 0.45)) { model.items.append(n) }
        }
        if panel == nil { build() }
        layout(animated: panel?.isVisible == false)
    }

    private func build() {
        let view = AlertView(model: model, onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        self.panel = p
        self.host = host
        model.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
            if items.isEmpty { self?.close() } else { self?.layout(animated: false) }
        }.store(in: &bag)
    }

    private func layout(animated: Bool) {
        guard let panel, let host, let screen = NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let target = NSRect(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10,
                            width: size.width, height: size.height)
        if animated {
            panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true, animate: panel.isVisible)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 40, dy: 0), display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            Task { @MainActor in self?.model.items.removeAll() }
        })
    }
}

struct AlertView: View {
    @ObservedObject var model: AlertModel
    var onClose: () -> Void
    @State private var pulse = false

    private var totalMemory: UInt64 { model.items.reduce(0) { $0 + $1.footprint } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.brandGradient).frame(width: 40, height: 40)
                        .scaleEffect(pulse ? 1.08 : 1)
                    Image(systemName: "bolt.badge.clock.fill").foregroundStyle(.white).font(.system(size: 18, weight: .semibold))
                }
                .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.items.count == 1 ? "1 app looks unused" : "\(model.items.count) apps look unused")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Stopping them frees about \(fmtBytes(totalMemory)) of memory")
                        .font(.system(size: 12)).foregroundStyle(Theme.t2)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.t2.opacity(0.6))
                }.buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.items) { item in
                        AlertRow(item: item) {
                            withAnimation(.spring(duration: 0.4)) { model.items.removeAll { $0.id == item.id } }
                        }
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Dismiss") { onClose() }.buttonStyle(.bordered).controlSize(.regular)
                Spacer()
                if model.items.count > 1 {
                    Button {
                        for i in model.items { Monitor.shared.stop(i.id) }
                        withAnimation(.spring(duration: 0.4)) { model.items.removeAll() }
                    } label: { Label("Quit all", systemImage: "power") }
                    .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.regular)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.edge))
    }
}

struct AlertRow: View {
    let item: FlaggedApp
    var onHandled: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: item.icon).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Chip(text: fmtBytes(item.footprint), icon: "memorychip")
                    if item.cpu >= 1 { Chip(text: "\(Int(item.cpu))%", icon: "cpu") }
                }
                ForEach(item.reasons, id: \.self) { r in
                    Text(r).font(.system(size: 11.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { Monitor.shared.stop(item.id); onHandled() } label: { Text("Quit app") }
                        .buttonStyle(.borderedProminent).tint(Theme.accentDeep).controlSize(.small)
                    Menu("Not now") {
                        Button("Remind me in 1 hour") { Monitor.shared.snooze(item.id); onHandled() }
                        Button("Never suggest this app") {
                            Monitor.shared.ignoreForever(bundleID: item.bundleID, id: item.id); onHandled()
                        }
                        Divider()
                        Button("Force quit", role: .destructive) { Monitor.shared.stop(item.id, force: true); onHandled() }
                    }
                    .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.card))
    }
}
