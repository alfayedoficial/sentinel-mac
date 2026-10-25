import XCTest
import SentinelCommon

/// The privileged helper runs as root, so its safety rules get the strictest tests.
final class HelperPolicyTests: XCTestCase {
    func testAllowsThirdPartyAgentAndDaemon() {
        XCTAssertNil(HelperPolicy.validate(label: "com.vendor.agent", plistPath: "/Library/LaunchAgents/com.vendor.agent.plist"))
        XCTAssertNil(HelperPolicy.validate(label: "com.vendor.daemon", plistPath: "/Library/LaunchDaemons/com.vendor.daemon.plist"))
    }

    func testRefusesAppleItems() {
        XCTAssertNotNil(HelperPolicy.validate(label: "com.apple.Finder", plistPath: "/Library/LaunchAgents/com.apple.Finder.plist"))
    }

    func testRefusesOtherFolders() {
        for path in ["/etc/passwd.plist", "/System/Library/LaunchDaemons/x.plist", "/Users/me/Library/LaunchAgents/x.plist",
                     "/Library/LaunchAgents/sub/x.plist", "/Library/LaunchAgentsEvil/x.plist", "/tmp/x.plist"] {
            XCTAssertNotNil(HelperPolicy.validate(label: "x", plistPath: path), path)
        }
    }

    func testRefusesPathTraversal() {
        XCTAssertNotNil(HelperPolicy.validate(label: "x", plistPath: "/Library/LaunchAgents/../../etc/passwd.plist"))
        XCTAssertNotNil(HelperPolicy.validate(label: "x", plistPath: "/Library/LaunchAgents/../LaunchDaemons/../../tmp/x.plist"))
    }

    func testRefusesNonPlistFiles() {
        XCTAssertNotNil(HelperPolicy.validate(label: "x", plistPath: "/Library/LaunchAgents/x.sh"))
        XCTAssertNotNil(HelperPolicy.validate(label: "x", plistPath: "/Library/LaunchAgents/x"))
    }

    func testRefusesUnsafeLabels() {
        for label in ["", "a b", "a/b", "../x", "x;rm -rf /", "x$(id)", "x\ny", "x\"y"] {
            XCTAssertNotNil(HelperPolicy.validate(label: label, plistPath: "/Library/LaunchAgents/x.plist"), label)
        }
    }

    func testDomainSelection() {
        XCTAssertEqual(HelperPolicy.domain(forDirectory: "/Library/LaunchDaemons", uid: 501), "system")
        XCTAssertEqual(HelperPolicy.domain(forDirectory: "/Library/LaunchAgents", uid: 501), "gui/501")
    }
}
