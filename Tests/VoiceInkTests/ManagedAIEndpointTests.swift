import Foundation
import XCTest

@testable import VoiceInk

/// Stands in for `ModeManager`, so tests see what happens to the default mode without saving modes.
final class FakeDefaultModeStore: DefaultModeStore {
    var mode: ModeConfig?
    private(set) var updates = 0

    init(provider: AIProvider? = nil, model: String? = nil) {
        if let provider {
            mode = ModeConfig(
                name: "Default", isAIEnhancementEnabled: true, selectedAIProvider: provider.rawValue,
                selectedAIModel: model, isDefault: true)
        }
    }

    func getDefaultConfiguration() -> ModeConfig? { mode }

    func updateConfiguration(_ updatedConfiguration: ModeConfig) {
        mode = updatedConfiguration
        updates += 1
    }
}

/// The managed AI endpoint: reading the keys, the cloud policy allowlist, the request it sends, and mode fallback.
@MainActor
final class ManagedAIEndpointTests: XCTestCase {
    private let token = "test-proxy-token"
    private let preferences = TestPreferences.defaults

    override func setUp() async throws {
        try await super.setUp()
        TestPreferences.reset()
        CloudPolicyMonitor.shared.start()
        CloudPolicyMonitor.shared.refresh()
        RecordingURLProtocol.start()
    }

    override func tearDown() async throws {
        RecordingURLProtocol.stop()
        TestPreferences.reset()
        CloudPolicyMonitor.shared.refresh()
        try await super.tearDown()
    }

    private func endpoint(_ url: String) -> ManagedAIEndpoint {
        ManagedAIEndpoint(baseURL: URL(string: url)!, model: "org-model", providerName: "Organization AI")
    }

    private func configureManagedEndpoint(_ url: String = "https://ai.example.com/v1", token: String? = nil) {
        preferences.set(url, forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        if let token {
            preferences.set(token, forKey: ManagedAIEndpoint.tokenKey)
        }
    }

    private func waitForPolicyChange(_ change: () -> Void) async {
        let notified = expectation(forNotification: .cloudPolicyDidChange, object: nil)
        change()
        await fulfillment(of: [notified], timeout: 5)
    }

    // MARK: - Reading the keys

    func testEndpointNeedsURLAndModel() {
        XCTAssertNil(ManagedAIEndpoint.current)

        preferences.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertNil(ManagedAIEndpoint.current, "A URL without a model isn't an endpoint")

        preferences.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        let endpoint = ManagedAIEndpoint.current
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "https://ai.example.com/v1")
        XCTAssertEqual(endpoint?.providerName, ManagedAIEndpoint.defaultProviderName)

        preferences.set("Acme AI", forKey: ManagedAIEndpoint.providerNameKey)
        XCTAssertEqual(ManagedAIEndpoint.current?.providerName, "Acme AI")
        XCTAssertEqual(AIProvider.managed.displayName, "Acme AI")

        preferences.set("ftp://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertNil(ManagedAIEndpoint.current, "Only HTTP and HTTPS URLs are endpoints")
    }

    func testEndpointURLWithUserInfoQueryOrFragmentIsRejected() {
        preferences.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        for url in [
            "https://user@ai.example.com/v1",
            "https://user:secret@ai.example.com/v1",
            "https://ai.example.com/v1?key=secret",
            "https://ai.example.com/v1?",
            "https://ai.example.com/v1#chat",
        ] {
            preferences.set(url, forKey: ManagedAIEndpoint.endpointURLKey)
            XCTAssertNil(ManagedAIEndpoint.current, url)

            let configured = endpoint(url)
            XCTAssertFalse(CloudPolicy.isManagedEndpointAllowed(configured), url)
            XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: configured), url)
            XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: true, managedEndpoint: configured), url)
        }

        preferences.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertNotNil(ManagedAIEndpoint.current)
    }

    func testChatCompletionsURL() {
        XCTAssertEqual(endpoint("https://ai.example.com/v1").chatCompletionsURL.absoluteString, "https://ai.example.com/v1/chat/completions")
        XCTAssertEqual(endpoint("https://ai.example.com/v1/").chatCompletionsURL.absoluteString, "https://ai.example.com/v1/chat/completions")
        XCTAssertEqual(
            endpoint("https://ai.example.com/v1/chat/completions").chatCompletionsURL.absoluteString,
            "https://ai.example.com/v1/chat/completions"
        )
    }

    // MARK: - Allowlist

    /// Only the managed provider guards the endpoint's token and redirects, so Custom and Ollama stay loopback-only.
    func testCustomAndOllamaStayLoopbackOnlyNextToManagedEndpoint() {
        let managed = endpoint("https://ai.example.com/v1")
        func customAllowed(_ url: String) -> Bool {
            CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: url, cloudAllowed: false, managedEndpoint: managed)
        }
        func ollamaAllowed(_ url: String) -> Bool {
            CloudPolicy.isEnhancementProviderAllowed(.ollama, ollamaBaseURL: url, cloudAllowed: false, managedEndpoint: managed)
        }

        for url in ["https://ai.example.com/v1", "https://ai.example.com/v1/chat/completions", "https://api.openai.com/v1"] {
            XCTAssertFalse(customAllowed(url), url)
            XCTAssertFalse(ollamaAllowed(url), url)
        }
        XCTAssertTrue(customAllowed("http://localhost:4000/v1"), "Loopback stays allowed")
        XCTAssertTrue(ollamaAllowed("http://127.0.0.1:11434"), "Loopback stays allowed")
        XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: managed))
        XCTAssertFalse(
            CloudPolicy.isEnhancementProviderAllowed(.openAI, cloudAllowed: false, managedEndpoint: managed),
            "A managed endpoint doesn't unblock other cloud providers"
        )
    }

    func testPlainHTTPManagedEndpointRefusedUnlessLoopback() {
        let remoteHTTP = endpoint("http://ai.example.com/v1")
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: remoteHTTP))

        let loopbackHTTP = endpoint("http://localhost:4000/v1")
        XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: loopbackHTTP))

        XCTAssertTrue(
            CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: endpoint("https://ai.example.com/v1"))
        )
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: true, managedEndpoint: nil))
    }

    // MARK: - Requests

    func testTokenSentOnlyToManagedEndpoint() async {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        configureManagedEndpoint(token: token)
        let service = AIService(defaultModeStore: FakeDefaultModeStore())

        do {
            _ = try await service.performChatCompletion(provider: .managed, modelName: nil, messages: [.user("hello")], timeout: 5)
            XCTFail("The recorder fails every request")
        } catch {
            XCTAssertNil(error as? CloudPolicyError, "The managed endpoint should pass the policy check: \(error)")
        }

        await withCustomProvider(baseURL: "http://127.0.0.1:9/v1") { model in
            _ = try? await service.performChatCompletion(provider: .custom, modelName: model, messages: [.user("hello")], timeout: 5)
        }

        do {
            _ = try await service.performChatCompletion(provider: .openAI, modelName: nil, messages: [.user("hello")])
            XCTFail("OpenAI should be refused")
        } catch {
            XCTAssertEqual(error as? CloudPolicyError, .cloudEnhancementDisabled(providerName: "OpenAI"))
        }

        let recorded = RecordingURLProtocol.authorizations
        let managedRequests = recorded.filter { $0.url.host == "ai.example.com" }
        XCTAssertFalse(managedRequests.isEmpty, "No request reached the managed endpoint: \(recorded.map(\.url))")
        XCTAssertTrue(managedRequests.allSatisfy { $0.authorization == "Bearer \(token)" }, "\(managedRequests)")
        XCTAssertEqual(
            Set(managedRequests.map(\.url.absoluteString)), ["https://ai.example.com/v1/chat/completions"])

        let otherRequests = recorded.filter { $0.url.host != "ai.example.com" }
        XCTAssertFalse(otherRequests.isEmpty, "The loopback custom request should be recorded")
        XCTAssertFalse(
            otherRequests.contains { $0.authorization?.contains(token) == true },
            "The managed token went to another host: \(otherRequests)"
        )
        XCTAssertFalse(recorded.contains { $0.url.host == "api.openai.com" })
    }

    /// The token stays in `ManagedAIToken`: a full request, a policy change, and a provider fallback save it nowhere
    /// else, neither in the credential store nor under another preference key.
    func testManagedTokenIsNotSavedAnywhereElse() async throws {
        let storedBefore = try XCTUnwrap(KeychainService.shared.memoryStoreValues)
        preferences.set("OpenAI", forKey: "selectedAIProvider")
        await waitForPolicyChange {
            preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
            configureManagedEndpoint(token: token)
        }
        let modes = FakeDefaultModeStore(provider: .openAI)
        let service = AIService(defaultModeStore: modes)
        XCTAssertEqual(service.selectedProvider, .managed)
        _ = try? await service.performChatCompletion(provider: .managed, modelName: nil, messages: [.user("hello")], timeout: 5)
        XCTAssertTrue(
            RecordingURLProtocol.authorizations.contains { $0.authorization == "Bearer \(token)" },
            "The request should have carried the token"
        )

        let tokenData = Data(token.utf8)
        let stored = try XCTUnwrap(KeychainService.shared.memoryStoreValues)
        XCTAssertFalse(stored.contains { $0.range(of: tokenData) != nil }, "The token was saved to the credential store")
        XCTAssertEqual(stored.count, storedBefore.count)
        for name in [AIProvider.managed.rawValue, AIProvider.managed.displayName] {
            XCTAssertNil(APIKeyManager.shared.getAPIKey(forProvider: name))
        }

        let saved = preferences.persistentDomain(forName: TestPreferences.suiteName) ?? [:]
        let keysHoldingToken = saved.filter { "\($0.value)".contains(token) }.map(\.key)
        XCTAssertEqual(keysHoldingToken, [ManagedAIEndpoint.tokenKey])
        XCTAssertFalse("\(modes.mode as Any)".contains(token))
    }

    // MARK: - Provider selection

    func testModeWithBlockedProviderUsesManagedProvider() {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        let service = AIService(defaultModeStore: FakeDefaultModeStore())

        XCTAssertEqual(
            ModeRuntimeResolver.resolvedProvider(providerName: "OpenAI", aiService: service), .openAI,
            "Without a managed provider, keep the blocked one so the user sees why"
        )

        configureManagedEndpoint()
        XCTAssertEqual(ModeRuntimeResolver.resolvedProvider(providerName: "OpenAI", aiService: service), .managed)
        XCTAssertEqual(ModeRuntimeResolver.resolvedProvider(providerName: "Custom", aiService: service), .managed)
        XCTAssertEqual(
            ModeRuntimeResolver.resolvedProvider(providerName: "VoiceInk Refine", aiService: service),
            service.connectedProviders.contains(.voiceInkRefine) ? .voiceInkRefine : nil,
            "Allowed providers aren't replaced"
        )
    }

    func testBlockedSelectionFallsBackToManagedProvider() {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        preferences.set("OpenAI", forKey: "selectedAIProvider")
        configureManagedEndpoint()
        let modes = FakeDefaultModeStore(provider: .openAI, model: "gpt-5")

        let service = AIService(defaultModeStore: modes)

        XCTAssertEqual(service.selectedProvider, .managed)
        XCTAssertEqual(preferences.string(forKey: "selectedAIProvider"), "Managed")
        XCTAssertEqual(modes.mode?.selectedAIProvider, "Managed", "The default mode follows the fallback")
        XCTAssertEqual(modes.mode?.selectedAIModel, "org-model")
    }

    func testBlockedSelectionFallsBackWhenCloudIsTurnedOff() async {
        preferences.set("OpenAI", forKey: "selectedAIProvider")
        configureManagedEndpoint()
        let modes = FakeDefaultModeStore(provider: .openAI)
        let service = AIService(defaultModeStore: modes)
        XCTAssertEqual(service.selectedProvider, .openAI, "Nothing is blocked while cloud services are on")

        await waitForPolicyChange { preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey) }

        XCTAssertEqual(service.selectedProvider, .managed)
        XCTAssertEqual(modes.mode?.selectedAIProvider, "Managed")
    }

    func testAllowedSelectionIsKeptWhenCloudIsOff() {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        preferences.set("Ollama", forKey: "selectedAIProvider")
        configureManagedEndpoint()
        let modes = FakeDefaultModeStore(provider: .ollama)

        let service = AIService(defaultModeStore: modes)

        XCTAssertEqual(service.selectedProvider, .ollama, "Loopback Ollama isn't blocked")
        XCTAssertEqual(modes.mode?.selectedAIProvider, "Ollama")
        XCTAssertEqual(modes.updates, 0)
    }

    /// Organization defaults come only from `DefaultEnhancementProvider` and `ManagedDefaultsVersion`, so a new
    /// endpoint or a rotated model leaves the selection alone whether the person or the organization chose it.
    func testEndpointChangesDontChangeTheSelection() async {
        preferences.set("OpenAI", forKey: "selectedAIProvider")
        let userModes = FakeDefaultModeStore(provider: .openAI)
        let userChoice = AIService(defaultModeStore: userModes)

        await waitForPolicyChange { configureManagedEndpoint() }
        preferences.set("Managed", forKey: "selectedAIProvider")
        let adminModes = FakeDefaultModeStore(provider: .managed, model: "org-model")
        let adminChoice = AIService(defaultModeStore: adminModes)
        XCTAssertEqual(userChoice.selectedProvider, .openAI, "A new endpoint isn't selected for the person")
        XCTAssertEqual(adminChoice.selectedProvider, .managed)

        await waitForPolicyChange { preferences.set("org-model-2", forKey: ManagedAIEndpoint.modelKey) }
        XCTAssertEqual(userChoice.selectedProvider, .openAI, "A rotated model isn't selected for the person")
        XCTAssertEqual(adminChoice.selectedProvider, .managed)
        XCTAssertEqual(adminChoice.selectedModel(for: .managed), "org-model-2")

        await waitForPolicyChange {
            preferences.set("https://ai2.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        }
        XCTAssertEqual(userChoice.selectedProvider, .openAI)
        XCTAssertEqual(adminChoice.selectedProvider, .managed)
        XCTAssertEqual(userModes.updates + adminModes.updates, 0, "The default modes weren't changed")
    }

    func testManagedKeyChangesApplyWhileRunning() async {
        let service = AIService(defaultModeStore: FakeDefaultModeStore())
        XCTAssertFalse(service.connectedProviders.contains(.managed))

        await waitForPolicyChange { configureManagedEndpoint(token: token) }
        XCTAssertEqual(CloudPolicyMonitor.shared.managedEndpoint?.model, "org-model")
        XCTAssertEqual(service.connectedProviders.first, .managed)
        service.selectedProvider = .managed

        await waitForPolicyChange {
            preferences.removeObject(forKey: ManagedAIEndpoint.endpointURLKey)
        }
        XCTAssertNil(CloudPolicyMonitor.shared.managedEndpoint)
        XCTAssertFalse(service.connectedProviders.contains(.managed))
        XCTAssertNotEqual(service.selectedProvider, .managed, "Moves off the provider once its endpoint is removed")
    }

    // MARK: - Helpers

    private func withCustomProvider(baseURL: String, _ body: (String) async throws -> Void) async rethrows {
        let manager = CustomAIProviderManager.shared
        let model = "policy-test-\(UUID().uuidString)"
        let provider = CustomAIProviderConfig(name: model, baseURL: baseURL, models: [model], selectedModel: model)
        XCTAssertTrue(manager.addProvider(provider, apiKey: "test-key"), "Couldn't save the test provider")
        defer {
            if let saved = manager.provider(forModel: model) {
                manager.deleteProvider(saved)
            }
        }
        try await body(model)
    }
}
