import Foundation
import SentinelCommon

/// Runs as root. Deliberately tiny: it can only switch off third-party launch items
/// that live directly inside /Library/LaunchAgents or /Library/LaunchDaemons.
final class Handler: NSObject, SentinelHelperProtocol {
    private let uid: uid_t
    init(uid: uid_t) { self.uid = uid }

    func version(reply: @escaping (String) -> Void) { reply("1") }

    func disableItem(label: String, plistPath: String, reply: @escaping (Bool, String) -> Void) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: plistPath).standardizedFileURL
        let dir = url.deletingLastPathComponent().path

        if let why = HelperPolicy.validate(label: label, plistPath: plistPath) { return reply(false, why) }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return reply(false, "File not found") }

        let domain = HelperPolicy.domain(forDirectory: dir, uid: uid)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "\(domain)/\(label)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()

        let dest = URL(fileURLWithPath: "/Library/SentinelDisabled", isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let target = dest.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
            reply(true, "")
        } catch {
            reply(false, error.localizedDescription)
        }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only the Sentinel app may talk to this helper.
        c.setCodeSigningRequirement("identifier \"\(appIdentifier)\"")
        c.exportedInterface = NSXPCInterface(with: SentinelHelperProtocol.self)
        c.exportedObject = Handler(uid: uid_t(c.effectiveUserIdentifier))
        c.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener(machServiceName: helperMachService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
