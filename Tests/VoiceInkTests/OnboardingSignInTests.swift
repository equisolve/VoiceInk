import SwiftData
import XCTest

@testable import VoiceInk

/// The practice steps that run AI enhancement through the organization endpoint, and Sign in with Equisolve before
/// them. Every test reads and writes its own defaults suite, never the app's settings.
@MainActor
final class OnboardingSignInTests: XCTestCase {
    private let endpointURL = "https://ai.example.com/v1"
    private let model = "voiceink-cleanup"
    private let signInURL = "https://hourglass.example.com"
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var isSignedIn = false

    override func setUp() async throws {
        suiteName = "OnboardingSignInTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        isSignedIn = false
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func setOrganizationEndpoint(signIn: Bool = true, token: String? = nil, provider: String? = "Managed") {
        defaults.set(endpointURL, forKey: ManagedAIEndpoint.endpointURLKey)
        defaults.set(model, forKey: ManagedAIEndpoint.modelKey)
        defaults.set(signIn ? signInURL : nil, forKey: ManagedAIEndpoint.signInURLKey)
        defaults.set(token, forKey: ManagedAIEndpoint.tokenKey)
        defaults.set(provider, forKey: ManagedDefaults.enhancementProviderKey)
    }

    /// A coordinator on the given practice step, with permissions, microphone, mode, and shortcut ready.
    private func makeCoordinator(on kind: OnboardingExperienceKind) throws -> OnboardingCoordinator {
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "test-microphone"
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.isManagedAISignedIn = { [unowned self] in isSignedIn }
        coordinator.permissionStatuses = Dictionary(
            uniqueKeysWithValues: OnboardingPermissionKind.allCases.map { ($0, .granted) })
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.experienceStepIndex = try XCTUnwrap(
            coordinator.activeExperienceSteps.firstIndex { $0.kind == kind }, "\(kind) step isn't shown")
        coordinator.isExperienceModeInstalled = true
        coordinator.hasExperienceModeShortcut = true
        return coordinator
    }

    // MARK: - The sign-in condition

    func testSignInIsRequiredOnlyWithSignInSetUpAndNoTokenOrKey() {
        let withSignIn = ManagedAIEndpoint(
            baseURL: URL(string: endpointURL)!, model: model, providerName: "Organization AI",
            signInURL: URL(string: signInURL)!)
        let withoutSignIn = ManagedAIEndpoint(
            baseURL: URL(string: endpointURL)!, model: model, providerName: "Organization AI")

        XCTAssertTrue(ManagedAIEndpoint.requiresSignIn(endpoint: withSignIn, profileToken: "", isSignedIn: false))
        XCTAssertFalse(ManagedAIEndpoint.requiresSignIn(endpoint: withSignIn, profileToken: "", isSignedIn: true))
        XCTAssertFalse(
            ManagedAIEndpoint.requiresSignIn(endpoint: withSignIn, profileToken: "profile-token", isSignedIn: false))
        XCTAssertFalse(ManagedAIEndpoint.requiresSignIn(endpoint: withoutSignIn, profileToken: "", isSignedIn: false))
        XCTAssertFalse(ManagedAIEndpoint.requiresSignIn(endpoint: nil, profileToken: "", isSignedIn: false))
    }

    func testSignInConditionMatchesTheCredentialRequests() {
        for (token, signedInKey) in [("", nil), ("", "key"), ("token", nil), ("token", "key")] as [(String, String?)] {
            let credential = ManagedAICredential.resolve(
                profileToken: token, signInConfigured: true, signedInKey: signedInKey)
            let endpoint = ManagedAIEndpoint(
                baseURL: URL(string: endpointURL)!, model: model, providerName: "Organization AI",
                signInURL: URL(string: signInURL)!)
            XCTAssertEqual(
                ManagedAIEndpoint.requiresSignIn(endpoint: endpoint, profileToken: token, isSignedIn: signedInKey != nil),
                credential == .signInRequired,
                "token \(token.isEmpty ? "unset" : "set"), key \(signedInKey == nil ? "unset" : "set")")
        }
    }

    // MARK: - Practice steps

    func testOrganizationProviderShowsTheAIPracticeStepsAndUsesTheEndpoint() throws {
        setOrganizationEndpoint()
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.isManagedSetup)
        XCTAssertTrue(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertEqual(coordinator.activeExperienceSteps.map(\.kind), [.dictation, .enhance, .email])
        XCTAssertEqual(coordinator.practiceEnhancementProvider.provider, .managed)
        XCTAssertEqual(coordinator.practiceEnhancementProvider.model, model)
    }

    func testAnotherManagedProviderKeepsTodaysPracticeSteps() {
        setOrganizationEndpoint(provider: "VoiceInk Refine")
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertTrue(coordinator.activeExperienceSteps.allSatisfy { !$0.requiresVerifiedAPIProvider })
        XCTAssertNotEqual(coordinator.practiceEnhancementProvider.provider, .managed)
    }

    func testLockedOrganizationProviderPracticesWithTheEndpoint() {
        setOrganizationEndpoint()
        defaults.set(true, forKey: EnhancementProviderLock.key)
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertEqual(coordinator.lockedEnhancementProvider?.provider, .managed)
        XCTAssertTrue(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertEqual(coordinator.practiceEnhancementProvider.provider, .managed)
        XCTAssertEqual(coordinator.practiceEnhancementProvider.model, model)
    }

    func testLockedProviderIsTheProviderThePracticeModesUse() {
        setOrganizationEndpoint(provider: "Ollama")
        defaults.set(true, forKey: EnhancementProviderLock.key)
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertEqual(coordinator.lockedEnhancementProvider?.provider, .ollama)
        XCTAssertFalse(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertEqual(coordinator.practiceEnhancementProvider.provider, .ollama)
    }

    // MARK: - Waiting for sign-in

    func testEnhancementStepWaitsForSignIn() throws {
        setOrganizationEndpoint()
        let coordinator = try makeCoordinator(on: .enhance)

        XCTAssertEqual(coordinator.experienceStep.kind, .enhance)
        XCTAssertTrue(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertEqual(coordinator.signInURLRequiredForCurrentExperience, URL(string: signInURL))
    }

    func testNextIsBlockedUntilSignInWhileSkipStaysAvailable() throws {
        setOrganizationEndpoint()
        let coordinator = try makeCoordinator(on: .enhance)

        XCTAssertTrue(coordinator.isCurrentExperienceReady(isTranscriptionSetupReady: true))
        XCTAssertFalse(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
        XCTAssertTrue(coordinator.canSkipCurrentExperience(isTranscriptionSetupReady: true))

        // A failed or canceled sign-in saves no key, so the step keeps waiting.
        XCTAssertFalse(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))

        isSignedIn = true
        XCTAssertFalse(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertTrue(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))

        // Signing out puts the wait back.
        isSignedIn = false
        XCTAssertFalse(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }

    func testEmailStepAlsoWaitsForSignIn() throws {
        setOrganizationEndpoint()
        let coordinator = try makeCoordinator(on: .email)

        XCTAssertTrue(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertFalse(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }

    func testDictationStepNeverWaits() throws {
        setOrganizationEndpoint()
        let coordinator = try makeCoordinator(on: .dictation)

        XCTAssertFalse(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertTrue(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }

    func testProfileTokenMeansNoWait() throws {
        setOrganizationEndpoint(token: "profile-token")
        let coordinator = try makeCoordinator(on: .enhance)

        XCTAssertFalse(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertTrue(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }

    func testEndpointWithoutSignInMeansNoWait() throws {
        setOrganizationEndpoint(signIn: false)
        let coordinator = try makeCoordinator(on: .enhance)

        XCTAssertFalse(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertTrue(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }

    func testVerifiedNonManagedProviderGetsNoWait() throws {
        // Sign-in is set up, but the profile doesn't pick the organization endpoint, and the person verified a cloud
        // key during onboarding, so practice runs on that provider.
        setOrganizationEndpoint(provider: nil)
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.isManagedAISignedIn = { [unowned self] in isSignedIn }
        coordinator.isSelectedAPIProviderVerified = true
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.experienceStepIndex = try XCTUnwrap(
            coordinator.activeExperienceSteps.firstIndex { $0.kind == .enhance })

        XCTAssertFalse(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertNotEqual(coordinator.practiceEnhancementProvider.provider, .managed)
        XCTAssertNil(coordinator.signInURLRequiredForCurrentExperience)
    }

    func testDisallowedEndpointGetsNoWait() throws {
        // With cloud services off, the organization endpoint must use https or a loopback host.
        setOrganizationEndpoint()
        defaults.set("http://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        defaults.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        let coordinator = try makeCoordinator(on: .dictation)
        coordinator.isSelectedAPIProviderVerified = true
        coordinator.experienceStepIndex = try XCTUnwrap(
            coordinator.activeExperienceSteps.firstIndex { $0.kind == .enhance })

        XCTAssertFalse(coordinator.practicesWithOrganizationEndpoint)
        XCTAssertNil(coordinator.signInURLRequiredForCurrentExperience)
    }

    func testOrganizationEndpointFollowsTheCloudPolicy() {
        setOrganizationEndpoint()
        defaults.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        XCTAssertTrue(
            OnboardingCoordinator(defaults: defaults).practicesWithOrganizationEndpoint,
            "An https endpoint stays allowed while cloud services are off")

        defaults.set("http://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertFalse(OnboardingCoordinator(defaults: defaults).practicesWithOrganizationEndpoint)

        defaults.set(false, forKey: CloudPolicy.disableCloudServicesKey)
        XCTAssertTrue(OnboardingCoordinator(defaults: defaults).practicesWithOrganizationEndpoint)
    }

    func testAdvanceRefusesWhileWaitingForSignIn() throws {
        setOrganizationEndpoint()
        let coordinator = try makeCoordinator(on: .enhance)
        let index = coordinator.experienceStepIndex
        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let enhancementService = AIEnhancementService(
            aiService: AIService(defaultModeStore: FakeDefaultModeStore()), modelContext: container.mainContext)

        coordinator.flow.advanceExperienceStep(isTranscriptionSetupReady: true, enhancementService: enhancementService)

        XCTAssertEqual(coordinator.experienceStepIndex, index)
        XCTAssertEqual(coordinator.stage, .experience)
        XCTAssertEqual(coordinator.experienceStep.kind, .enhance)
    }

    func testWithoutManagedKeysTheStepIsUnchanged() throws {
        defaults.set(true, forKey: OnboardingStorageKeys.skippedAPISetup)
        let skipped = OnboardingCoordinator(defaults: defaults)
        XCTAssertFalse(skipped.practicesWithOrganizationEndpoint)
        XCTAssertTrue(skipped.activeExperienceSteps.allSatisfy { !$0.requiresVerifiedAPIProvider })
        defaults.removeObject(forKey: OnboardingStorageKeys.skippedAPISetup)

        let coordinator = try makeCoordinator(on: .enhance)
        coordinator.isSelectedAPIProviderVerified = true
        XCTAssertFalse(coordinator.isCurrentExperienceWaitingForSignIn)
        XCTAssertNil(coordinator.signInURLRequiredForCurrentExperience)
        XCTAssertEqual(
            coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true),
            coordinator.isCurrentExperienceReady(isTranscriptionSetupReady: true))
        XCTAssertTrue(coordinator.canAdvanceCurrentExperience(isTranscriptionSetupReady: true))
    }
}
