import AppKit
import ServiceManagement
import SentinelCommon

/// Talks to the root helper that is approved once in System Settings, so no password per action.
enum PrivilegedHelper {
    static let plistName = "com.afapps.sentinel.helper.plist"
    static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    enum Readiness { case ready, needsApproval, unavailable(String) }

    static func prepare() -> Readiness {
        let s = service
        switch s.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        default: break
        }
        do { try s.register() } catch {
            if s.status == .requiresApproval { return .needsApproval }
            if s.status == .enabled { return .ready }
            return .unavailable(error.localizedDescription)
        }
        switch s.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        default: return .unavailable("status \(s.status.rawValue)")
        }
    }

    static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func run(_ f: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            if !fired { fired = true; f() }
        }
    }

    static func disable(label: String, path: String) async -> (Bool, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            let conn = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: SentinelHelperProtocol.self)
            conn.setCodeSigningRequirement("identifier \"\(helperMachService)\"")
            let once = Once()
            let finish: (Bool, String) -> Void = { ok, msg in
                once.run { conn.invalidate(); cont.resume(returning: (ok, msg)) }
            }
            conn.resume()
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ finish(false, $0.localizedDescription) })
                    as? SentinelHelperProtocol else { return finish(false, "Helper unavailable") }
            proxy.disableItem(label: label, plistPath: path) { ok, msg in finish(ok, msg) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { finish(false, "Helper timed out") }
        }
    }
}
