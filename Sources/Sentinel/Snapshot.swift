import AppKit
import SwiftUI

/// Renders the real SwiftUI screens to PNG files (with demo data) for the documentation and website.
@MainActor
enum Snapshot {
    static func run() async {
        let dir = Demo.outputFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DemoData.apply()

        let screens: [(String, Tab, ToolKind?)] = [
            ("overview", .overview, nil), ("apps", .background, nil), ("clean", .clean, nil), ("tools", .tools, nil),
            ("settings", .settings, nil), ("smart-care", .tools, .smart), ("uninstaller", .tools, .uninstall),
            ("big-files", .tools, .bigFiles), ("duplicates", .tools, .duplicates), ("space-lens", .tools, .spaceLens),
            ("startup", .tools, .startup), ("maintenance", .tools, .maintenance), ("history", .tools, .history),
            ("threat-watch", .tools, .threats),
        ]
        for (name, tab, tool) in screens {
            await render(MainView(tab: tab, tool: tool), size: CGSize(width: 400, height: 580), dark: true, to: dir.appendingPathComponent("\(name)-dark.png"))
        }
        for (name, tab, tool) in [("overview", Tab.overview, nil as ToolKind?), ("clean", .clean, nil), ("settings", .settings, nil), ("tools", .tools, nil)] {
            await render(MainView(tab: tab, tool: tool), size: CGSize(width: 400, height: 580), dark: false, to: dir.appendingPathComponent("\(name)-light.png"))
        }

        // the two popups
        let alertModel = AlertModel()
        alertModel.items = Monitor.shared.flagged
        await render(AlertView(model: alertModel, onClose: {}), size: nil, dark: true, to: dir.appendingPathComponent("popup-unused-apps.png"))
        let threatModel = ThreatModel()
        threatModel.items = ThreatWatch.shared.threats
        await render(ThreatAlertView(model: threatModel, onClose: {}), size: nil, dark: true, to: dir.appendingPathComponent("popup-threat.png"))
        print("Snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, size: CGSize?, dark: Bool, to file: URL) async {
        let host = NSHostingView(rootView: view)
        let fitted = size ?? CGSize(width: host.fittingSize.width + 40, height: host.fittingSize.height + 40)
        host.frame = NSRect(origin: .zero, size: fitted)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = size == nil ? .clear : .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 1_600_000_000)          // let entrance animations finish
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        window.orderOut(nil)
    }
}
