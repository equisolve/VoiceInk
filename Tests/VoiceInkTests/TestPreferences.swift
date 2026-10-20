import Foundation
import XCTest

@testable import VoiceInk

/// The suite that stands in for the app's preferences during tests. See `AppPreferences`.
enum TestPreferences {
    static let suiteName = "com.prakashjoshipax.VoiceInk.Tests"
    static let defaults = UserDefaults(suiteName: suiteName)!

    /// Empties the suite, so a test starts with no policy, managed endpoint, or provider selection.
    static func reset() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// The test bundle's principal class (`NSPrincipalClass`). Before any test runs, it points `AppPreferences` at the
/// test suite. After each test, it fails the test if the test wrote to the app's own preferences.
@objc(VoiceInkTestObserver)
final class VoiceInkTestObserver: NSObject, XCTestObservation {
    override init() {
        super.init()
        AppPreferences.defaults = TestPreferences.defaults
        TestPreferences.reset()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let before = Self.appDomain()
        testCase.addTeardownBlock {
            let after = Self.appDomain()
            guard after != before else { return }
            let keys = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
            XCTFail("The test wrote to the app's preferences (\(keys.joined(separator: ", "))). Use TestPreferences.")
        }
    }

    /// The host app's own preferences, as property-list values that compare by value.
    private static func appDomain() -> [String: NSObject] {
        guard let domain = Bundle.main.bundleIdentifier,
            let values = UserDefaults.standard.persistentDomain(forName: domain)
        else {
            return [:]
        }
        return values.compactMapValues { $0 as? NSObject }
    }
}
