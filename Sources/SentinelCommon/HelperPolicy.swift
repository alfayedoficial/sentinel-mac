import Foundation

/// The rules the privileged helper enforces. Kept here so they can be unit-tested.
public enum HelperPolicy {
    public static let allowedDirectories = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]

    /// Returns nil when the request is allowed, otherwise the reason it is refused.
    public static func validate(label: String, plistPath: String) -> String? {
        let url = URL(fileURLWithPath: plistPath).standardizedFileURL
        let dir = url.deletingLastPathComponent().path
        guard allowedDirectories.contains(dir) else { return "Folder not allowed" }
        guard url.pathExtension == "plist" else { return "Not a plist" }
        guard label.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return "Label not allowed" }
        guard !label.hasPrefix("com.apple.") else { return "Apple items are protected" }
        return nil
    }

    /// launchd domain for the folder the plist lives in.
    public static func domain(forDirectory dir: String, uid: UInt32) -> String {
        dir == "/Library/LaunchDaemons" ? "system" : "gui/\(uid)"
    }
}
