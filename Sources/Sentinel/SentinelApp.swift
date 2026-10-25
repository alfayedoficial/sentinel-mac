import AppKit
import SwiftUI

@main
struct SentinelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MainView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Demo.enabled {
            Task { @MainActor in await Snapshot.run(); NSApp.terminate(nil) }
            return
        }
        Task { @MainActor in
            Monitor.shared.onNewFlags = { AlertPresenter.shared.show($0) }
            Monitor.shared.start()
            WeeklyCheck.shared.start()
            ThreatWatch.shared.onNewThreats = { ThreatPresenter.shared.show($0) }
            ThreatWatch.shared.start()
            Updater.shared.start()
            // `--install-update` checks GitHub and installs a newer release without clicking (handy for scripts and tests).
            if CommandLine.arguments.contains("--install-update") {
                Task { @MainActor in await Updater.shared.check(); await Updater.shared.install() }
            }
            // One-time permission: register the privileged helper so system items can be switched off without a password each time.
            // Only for a real install: a copy run from /tmp or a build folder must not register itself as a background item.
            let path = Bundle.main.bundlePath
            let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
            if installed, case .needsApproval = PrivilegedHelper.prepare(), !UserDefaults.standard.bool(forKey: "helperApprovalShown") {
                UserDefaults.standard.set(true, forKey: "helperApprovalShown")
                PrivilegedHelper.openApprovalSettings()
            }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var bar = Monitor.shared.bar

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: bar.threat ? "exclamationmark.shield.fill" : bar.alert ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
            Text("\(bar.percent)%").monospacedDigit()
        }
    }
}
