import XCTest

@testable import VoiceInk

/// Every test reads and writes its own defaults suite, never the app's settings.
@MainActor
final class GitHubStarPromptPolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "GitHubStarPromptPolicyTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testKeyNames() {
        XCTAssertEqual(GitHubStarPromptPolicy.hidePromptKey, "HideGitHubStarPrompt")
        XCTAssertEqual(GitHubStarPromptPolicy.showPromptKey, "ShowGitHubStarPrompt")
    }

    func testShowsByDefault() {
        XCTAssertTrue(GitHubStarPromptPolicy.isPromptAllowed(in: defaults))
        XCTAssertFalse(GitHubStarPromptPolicy.isHiddenByPolicy(in: defaults))
        XCTAssertTrue(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }

    func testPolicyHidesPromptEvenWhenSettingIsOn() {
        defaults.set(true, forKey: GitHubStarPromptPolicy.hidePromptKey)
        defaults.set(true, forKey: GitHubStarPromptPolicy.showPromptKey)

        XCTAssertTrue(GitHubStarPromptPolicy.isHiddenByPolicy(in: defaults))
        XCTAssertFalse(GitHubStarPromptPolicy.isPromptAllowed(in: defaults))
        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }

    func testPolicyHidesPromptWhenSettingIsUnset() {
        defaults.set(true, forKey: GitHubStarPromptPolicy.hidePromptKey)

        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }

    func testSettingOffHidesPromptWithoutPolicy() {
        defaults.set(false, forKey: GitHubStarPromptPolicy.showPromptKey)

        XCTAssertFalse(GitHubStarPromptPolicy.isHiddenByPolicy(in: defaults))
        XCTAssertFalse(GitHubStarPromptPolicy.isPromptAllowed(in: defaults))
        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }

    func testPolicyFalseLeavesTheSettingInCharge() {
        defaults.set(false, forKey: GitHubStarPromptPolicy.hidePromptKey)
        XCTAssertTrue(GitHubStarPromptCoordinator.shouldShow(in: defaults))

        defaults.set(false, forKey: GitHubStarPromptPolicy.showPromptKey)
        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }

    func testSettingOnStillFollowsTheExistingSchedule() {
        defaults.set(true, forKey: GitHubStarPromptPolicy.showPromptKey)
        XCTAssertTrue(GitHubStarPromptCoordinator.shouldShow(in: defaults))

        defaults.set(true, forKey: GitHubStarPromptCoordinator.Keys.hasDeferredOnce)
        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))

        defaults.removeObject(forKey: GitHubStarPromptCoordinator.Keys.hasDeferredOnce)
        defaults.set(true, forKey: GitHubStarPromptCoordinator.Keys.hasStarred)
        XCTAssertFalse(GitHubStarPromptCoordinator.shouldShow(in: defaults))
    }
}
