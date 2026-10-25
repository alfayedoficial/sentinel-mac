import Foundation

public let helperMachService = "com.afapps.sentinel.helper"
public let appIdentifier = "com.afapps.sentinel"

/// The only things the privileged helper will ever do for the app.
@objc public protocol SentinelHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Stops a third-party launch agent/daemon and moves its plist to /Library/SentinelDisabled.
    func disableItem(label: String, plistPath: String, reply: @escaping (Bool, String) -> Void)
}
