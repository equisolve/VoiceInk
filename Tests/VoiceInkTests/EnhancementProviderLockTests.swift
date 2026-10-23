import SwiftData
import XCTest

@testable import VoiceInk

/// Checks `LockEnhancementProvider` and what the AI model rows and chips show. Uses the test preferences suite.
@MainActor
final class EnhancementProviderLockTests: XCTestCase {
    private let preferences = TestPreferences.defaults
    private let endpoint = ManagedAIEndpoint(
        baseURL: URL(string: "https://ai.example.com/v1")!, model: "voiceink-cleanup", providerName: "Organization AI")

    override func setUp() async throws {
        TestPreferences.reset()
    }

    override func tearDown() async throws {
        TestPreferences.reset()
    }

    private func setManagedEndpoint(_ url: String = "https://ai.example.com/v1") {
        preferences.set(url, forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set("voiceink-cleanup", forKey: ManagedAIEndpoint.modelKey)
    }

    private func resolve(
        cloudAllowed: Bool = false,
        refineUnavailableReason: String? = nil,
        endpoint: ManagedAIEndpoint? = nil
    ) -> (lock: EnhancementProviderLock?, ignored: [String]) {
        EnhancementProviderLock.resolve(
            defaults: preferences,
            isCloudAllowed: cloudAllowed,
            voiceInkRefineUnavailableReason: refineUnavailableReason,
            managedEndpoint: endpoint
        )
    }

    // MARK: - Resolving the lock

    func testLockOffLocksNothing() {
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)

        XCTAssertNil(resolve(endpoint: endpoint).lock, "Without the key, DefaultEnhancementProvider is only a default")

        preferences.set(false, forKey: EnhancementProviderLock.key)
        XCTAssertNil(resolve(endpoint: endpoint).lock)
    }

    func testLockWithoutADefaultProviderLocksNothing() {
        preferences.set(true, forKey: EnhancementProviderLock.key)

        let result = resolve(endpoint: endpoint)

        XCTAssertNil(result.lock)
        XCTAssertFalse(result.ignored.isEmpty)
    }

    func testLocksTheOrganizationProviderWithItsModel() {
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)

        XCTAssertEqual(
            resolve(endpoint: endpoint).lock,
            EnhancementProviderLock(provider: .managed, model: "voiceink-cleanup"))
    }

    func testUnusableOrganizationProviderFallsBackToRefine() {
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)
        let plainHTTP = ManagedAIEndpoint(
            baseURL: URL(string: "http://ai.example.com/v1")!, model: "voiceink-cleanup", providerName: "Organization AI")

        let withoutEndpoint = resolve(endpoint: nil)
        XCTAssertEqual(withoutEndpoint.lock?.provider, .voiceInkRefine)
        XCTAssertFalse(withoutEndpoint.ignored.isEmpty, "The fallback is logged")

        XCTAssertEqual(resolve(endpoint: plainHTTP).lock?.provider, .voiceInkRefine)
    }

    func testNothingIsLockedWhenNeitherTheProviderNorRefineCanRun() {
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)

        XCTAssertNil(resolve(refineUnavailableReason: "Needs Apple silicon", endpoint: nil).lock)

        preferences.set("VoiceInk Refine", forKey: ManagedDefaults.enhancementProviderKey)
        XCTAssertNil(resolve(refineUnavailableReason: "Needs Apple silicon", endpoint: endpoint).lock)
    }

    func testBlockedCloudProviderIsNotLocked() {
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("OpenAI", forKey: ManagedDefaults.enhancementProviderKey)
        preferences.set("gpt-6-luna", forKey: ManagedDefaults.enhancementModelKey)

        XCTAssertNil(resolve(cloudAllowed: false).lock)
        XCTAssertEqual(
            resolve(cloudAllowed: true).lock, EnhancementProviderLock(provider: .openAI, model: "gpt-6-luna"))
    }

    // MARK: - Modes at run time

    private func enhancementConfiguration(for mode: ModeConfig) throws -> EnhancementRuntimeConfiguration {
        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let aiService = AIService(defaultModeStore: FakeDefaultModeStore())
        let service = AIEnhancementService(aiService: aiService, modelContext: container.mainContext)
        return ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: mode, enhancementService: service, aiService: aiService)
    }

    private var savedModes: [ModeConfig] {
        [
            ModeConfig(
                name: "Refine", isAIEnhancementEnabled: true, selectedAIProvider: "VoiceInk Refine",
                selectedAIModel: VoiceInkRefineService.modelName),
            ModeConfig(name: "Ollama", isAIEnhancementEnabled: true, selectedAIProvider: "Ollama", selectedAIModel: "mistral"),
            ModeConfig(
                name: "Gemini", isAIEnhancementEnabled: true, selectedAIProvider: "Gemini",
                selectedAIModel: "gemini-3.8-flash"),
            ModeConfig(name: "Unset", isAIEnhancementEnabled: true),
        ]
    }

    func testLockResolvesEveryModeToTheLockedProvider() throws {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        setManagedEndpoint()
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)

        for mode in savedModes {
            let configuration = try enhancementConfiguration(for: mode)
            XCTAssertEqual(configuration.provider, .managed, mode.name)
            XCTAssertEqual(configuration.modelName, "voiceink-cleanup", mode.name)
            XCTAssertTrue(configuration.isEnabled, "The person keeps the on/off switch")
        }
    }

    func testLockedModesKeepTheirSavedProvider() throws {
        setManagedEndpoint()
        preferences.set(true, forKey: EnhancementProviderLock.key)
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)
        let mode = savedModes[1]

        XCTAssertEqual(try enhancementConfiguration(for: mode).provider, .managed)
        XCTAssertEqual(mode.selectedAIProvider, "Ollama")

        preferences.removeObject(forKey: EnhancementProviderLock.key)
        XCTAssertNotEqual(try enhancementConfiguration(for: mode).provider, .managed, "Unlocking restores the mode's provider")
    }

    func testLockOffLeavesModesUnchanged() throws {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        setManagedEndpoint()
        preferences.set("Managed", forKey: ManagedDefaults.enhancementProviderKey)
        let gemini = savedModes[2]

        // A blocked cloud provider still moves to the organization provider, as before the lock existed.
        XCTAssertEqual(try enhancementConfiguration(for: gemini).provider, .managed)

        preferences.removeObject(forKey: CloudPolicy.disableCloudServicesKey)
        let unmanaged = try enhancementConfiguration(for: gemini)
        XCTAssertNotEqual(unmanaged.provider, .managed)
    }

    func testEffectiveModelKeepsTheSavedModelOnlyForTheLockedProvider() {
        let ollamaLock = EnhancementProviderLock(provider: .ollama, model: nil)

        XCTAssertEqual(
            EnhancementProviderLock.effectiveModelName(savedProvider: "Ollama", savedModel: "llama3", lock: ollamaLock),
            "llama3")
        XCTAssertNil(
            EnhancementProviderLock.effectiveModelName(savedProvider: "Gemini", savedModel: "gemini-3.8-flash", lock: ollamaLock))
        XCTAssertEqual(
            EnhancementProviderLock.effectiveModelName(
                savedProvider: "Gemini", savedModel: "gemini-3.8-flash",
                lock: EnhancementProviderLock(provider: .managed, model: "voiceink-cleanup")),
            "voiceink-cleanup")
        XCTAssertEqual(
            EnhancementProviderLock.effectiveModelName(savedProvider: "Gemini", savedModel: "gemini-3.8-flash", lock: nil),
            "gemini-3.8-flash")
    }

    // MARK: - Model rows and chips

    func testOrganizationProviderHasNoModelPicker() {
        XCTAssertFalse(EnhancementModelDisplay.showsModelPicker(for: .managed))
        for provider in AIProvider.allCases where provider != .managed {
            XCTAssertTrue(EnhancementModelDisplay.showsModelPicker(for: provider), provider.rawValue)
        }
    }

    func testOrganizationChipShowsTheProviderNameNotTheModelAlias() {
        setManagedEndpoint()

        XCTAssertEqual(
            EnhancementModelDisplay.chipLabel(providerName: "Managed", modelName: "voiceink-cleanup"), "Organization AI")
        XCTAssertEqual(EnhancementModelDisplay.chipLabel(providerName: "Managed", modelName: nil), "Organization AI")

        preferences.set("Example AI", forKey: ManagedAIEndpoint.providerNameKey)
        XCTAssertEqual(
            EnhancementModelDisplay.chipLabel(providerName: "Managed", modelName: "voiceink-cleanup"), "Example AI")
    }

    func testOtherChipsShowTheModelAsBefore() {
        XCTAssertEqual(EnhancementModelDisplay.chipLabel(providerName: "Gemini", modelName: "gemini-3.8-flash"), "gemini-3.8-flash")
        XCTAssertEqual(EnhancementModelDisplay.chipLabel(providerName: "Ollama", modelName: "mistral"), "mistral")
        XCTAssertNil(EnhancementModelDisplay.chipLabel(providerName: "Gemini", modelName: ""))
        XCTAssertNil(EnhancementModelDisplay.chipLabel(providerName: "Gemini", modelName: nil))
        XCTAssertNil(EnhancementModelDisplay.chipLabel(providerName: "Local CLI", modelName: "local-cli"))
    }

    // MARK: - The provider that runs

    private func resolution(
        saved: String?,
        lock: EnhancementProviderLock? = nil,
        cloudAllowed: Bool = false,
        allowed: Set<AIProvider> = [.managed, .voiceInkRefine, .ollama],
        connected: [AIProvider] = [.managed, .voiceInkRefine, .ollama]
    ) -> EnhancementProviderResolution {
        EnhancementProviderResolution.resolve(
            savedProviderName: saved,
            lock: lock,
            isCloudAllowed: cloudAllowed,
            isAllowed: { allowed.contains($0) },
            connectedProviders: connected
        )
    }

    func testBlockedCloudProviderRunsTheOrganizationProvider() {
        XCTAssertEqual(resolution(saved: "Groq"), .provider(.managed))
    }

    func testBlockedCloudProviderWithoutAnOrganizationProviderRunsNothing() {
        let result = resolution(saved: "Groq", allowed: [.voiceInkRefine, .ollama], connected: [.voiceInkRefine, .ollama])
        XCTAssertEqual(result, .blocked(.groq))
        XCTAssertNil(result.runningProvider)
    }

    func testLockWinsOverTheSavedProvider() {
        let lock = EnhancementProviderLock(provider: .voiceInkRefine, model: nil)
        XCTAssertEqual(resolution(saved: "Groq", lock: lock), .provider(.voiceInkRefine))
        XCTAssertEqual(resolution(saved: "Ollama", lock: lock), .provider(.voiceInkRefine))
    }

    func testAllowedSavedProviderRuns() {
        XCTAssertEqual(resolution(saved: "Ollama"), .provider(.ollama))
        XCTAssertEqual(
            resolution(saved: "Groq", cloudAllowed: true, allowed: [], connected: [.groq, .ollama]), .provider(.groq))
    }

    func testUnconnectedOrUnknownProviderIsUnavailable() {
        XCTAssertEqual(resolution(saved: "Groq", cloudAllowed: true, connected: [.ollama]), .unavailable)
        XCTAssertEqual(resolution(saved: "Not a provider"), .unavailable)
    }

    func testNoSavedProviderRunsTheFirstConnectedOne() {
        XCTAssertEqual(resolution(saved: nil), .provider(.managed))
        XCTAssertEqual(resolution(saved: nil, connected: []), .unavailable)
    }

    func testChipShowsTheProviderThatRuns() {
        XCTAssertEqual(
            EnhancementModelDisplay.chipLabel(
                resolution: .provider(.managed), savedProviderName: "Groq", savedModelName: "qwen/qwen3.8-27b",
                lock: nil),
            "Organization AI")
        XCTAssertEqual(
            EnhancementModelDisplay.chipLabel(
                resolution: .blocked(.groq), savedProviderName: "Groq", savedModelName: "qwen/qwen3.8-27b", lock: nil),
            "No AI enhancement")
        XCTAssertEqual(
            EnhancementModelDisplay.chipLabel(
                resolution: .provider(.ollama), savedProviderName: "Ollama", savedModelName: "mistral", lock: nil),
            "mistral")
    }

    /// The mode list and the recording path read the same function, so they name the same provider.
    func testModeListAndRecordingAgreeOnABlockedProvider() throws {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        setManagedEndpoint()
        let mode = ModeConfig(
            name: "Email", isAIEnhancementEnabled: true, selectedAIProvider: "Groq", selectedAIModel: "qwen/qwen3.8-27b")
        let aiService = AIService(defaultModeStore: FakeDefaultModeStore())

        let listed = ModeRuntimeResolver.enhancementProviderResolution(
            savedProviderName: mode.selectedAIProvider, savedModelName: mode.selectedAIModel,
            connectedProviders: aiService.connectedProviders)
        XCTAssertEqual(listed, .provider(.managed))
        XCTAssertEqual(try enhancementConfiguration(for: mode).provider, listed.runningProvider)
        XCTAssertEqual(mode.selectedAIProvider, "Groq", "The saved provider is kept")

        preferences.removeObject(forKey: ManagedAIEndpoint.endpointURLKey)
        let withoutEndpoint = ModeRuntimeResolver.enhancementProviderResolution(
            savedProviderName: mode.selectedAIProvider, savedModelName: mode.selectedAIModel,
            connectedProviders: aiService.connectedProviders)
        XCTAssertEqual(withoutEndpoint, .blocked(.groq))
    }
}
