import XCTest

@testable import VoiceInk

/// The shortcut step in onboarding: the organization's `DefaultShortcut` and the line that explains how to use the
/// shortcut. Every test reads and writes its own defaults suite, never the app's settings.
@MainActor
final class OnboardingShortcutRecommendationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "OnboardingShortcutRecommendationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(on kind: OnboardingExperienceKind = .dictation) throws -> OnboardingCoordinator {
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.primaryRecordingShortcutMode = { .hybrid }
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.experienceStepIndex = try XCTUnwrap(
            coordinator.activeExperienceSteps.firstIndex { $0.kind == kind }, "\(kind) step isn't shown")
        return coordinator
    }

    func testValidShortcutIsPreselected() throws {
        defaults.set("rightOption", forKey: ManagedDefaults.shortcutKey)
        let coordinator = try makeCoordinator()

        XCTAssertEqual(coordinator.experienceShortcutAction, .primaryRecording)
        XCTAssertEqual(coordinator.recommendedShortcut, ShortcutMigration.presetShortcut(named: "rightOption"))
        XCTAssertEqual(coordinator.experienceIntroShortcut, coordinator.recommendedShortcut)
    }

    func testInvalidShortcutIsIgnored() throws {
        defaults.set("hyperKey", forKey: ManagedDefaults.shortcutKey)
        let coordinator = try makeCoordinator()

        XCTAssertNil(coordinator.recommendedShortcut)
        XCTAssertNil(coordinator.experienceIntroShortcut)
        XCTAssertFalse(coordinator.isUsingRecommendedShortcut)
    }

    func testWithoutTheKeyThePersonPicksTheShortcut() throws {
        let coordinator = try makeCoordinator()

        XCTAssertNil(coordinator.experienceIntroShortcut)
        XCTAssertFalse(coordinator.isUsingRecommendedShortcut)
    }

    func testUsageLineShowsOnTheShortcutStepInHybridMode() throws {
        let coordinator = try makeCoordinator()
        XCTAssertTrue(coordinator.showsShortcutUsageHint)

        for mode in [RecordingShortcutManager.Mode.toggle, .pushToTalk, .doubleTap] {
            coordinator.primaryRecordingShortcutMode = { mode }
            XCTAssertFalse(coordinator.showsShortcutUsageHint, mode.rawValue)
        }
    }

    func testUsageLineStaysOffTheOtherSteps() throws {
        for kind in [OnboardingExperienceKind.enhance, .email] {
            let coordinator = try makeCoordinator(on: kind)
            XCTAssertFalse(coordinator.showsShortcutUsageHint, "\(kind)")
        }
    }
}
