import AppKit
import XCTest

@testable import VoiceInk

/// The test host runs on Macs that also have VoiceInk installed. These checks keep a test run away from that copy's
/// settings and from the login Keychain.
final class TestIsolationTests: XCTestCase {
    func testHostIsNotTheInstalledApp() {
        XCTAssertTrue(ProcessInfo.processInfo.isRunningUnitTests)
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.prakashjoshipax.VoiceInk")
    }

    @MainActor
    func testHostShowsNoWindowsOrDockIcon() {
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        XCTAssertEqual(NSApplication.shared.windows.filter(\.isVisible), [])
    }

    func testCredentialsStayInMemory() {
        let keychain = KeychainService.shared
        XCTAssertTrue(keychain.usesMemoryStore)
        XCTAssertEqual(keychain.service, "com.prakashjoshipax.VoiceInk.Tests")

        let key = "TestIsolation_\(UUID().uuidString)"
        XCTAssertFalse(keychain.exists(forKey: key))
        XCTAssertTrue(keychain.save("secret", forKey: key))
        XCTAssertEqual(keychain.getString(forKey: key), "secret")
        XCTAssertTrue(keychain.delete(forKey: key))
        XCTAssertFalse(keychain.exists(forKey: key))
    }

    func testAPIKeyManagerUsesTheMemoryStore() {
        let provider = "TestIsolationProvider\(UUID().uuidString)"
        XCTAssertFalse(APIKeyManager.shared.hasAPIKey(forProvider: provider))
        XCTAssertTrue(APIKeyManager.shared.saveAPIKey("key", forProvider: provider))
        XCTAssertTrue(APIKeyManager.shared.hasAPIKey(forProvider: provider))
        APIKeyManager.shared.deleteAPIKey(forProvider: provider)
        XCTAssertFalse(APIKeyManager.shared.hasAPIKey(forProvider: provider))
    }
}
