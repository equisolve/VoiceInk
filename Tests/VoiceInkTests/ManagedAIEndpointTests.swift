import Foundation
import XCTest

@testable import VoiceInk

/// The managed AI endpoint: reading the keys, the cloud policy allowlist, the request it sends, and mode fallback.
@MainActor
final class ManagedAIEndpointTests: XCTestCase {
    private let token = "test-proxy-token"
    private let savedKeys =
        [CloudPolicy.disableCloudServicesKey, "selectedAIProvider", "ManagedAIProviderSelectedEndpoint"]
        + ManagedAIEndpoint.allKeys
    private var savedValues: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        for key in savedKeys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        CloudPolicyMonitor.shared.start()
        CloudPolicyMonitor.shared.refresh()
        RecordingURLProtocol.start()
    }

    override func tearDown() async throws {
        RecordingURLProtocol.stop()
        for key in savedKeys {
            UserDefaults.standard.set(savedValues[key], forKey: key)
        }
        CloudPolicyMonitor.shared.refresh()
        try await super.tearDown()
    }

    private func endpoint(_ url: String) -> ManagedAIEndpoint {
        ManagedAIEndpoint(baseURL: URL(string: url)!, model: "org-model", providerName: "Organization AI")
    }

    private func configureManagedEndpoint(_ url: String = "https://ai.example.com/v1", token: String? = nil) {
        UserDefaults.standard.set(url, forKey: ManagedAIEndpoint.endpointURLKey)
        UserDefaults.standard.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        if let token {
            UserDefaults.standard.set(token, forKey: ManagedAIEndpoint.tokenKey)
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

        UserDefaults.standard.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertNil(ManagedAIEndpoint.current, "A URL without a model isn't an endpoint")

        UserDefaults.standard.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        let endpoint = ManagedAIEndpoint.current
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "https://ai.example.com/v1")
        XCTAssertEqual(endpoint?.providerName, ManagedAIEndpoint.defaultProviderName)

        UserDefaults.standard.set("Acme AI", forKey: ManagedAIEndpoint.providerNameKey)
        XCTAssertEqual(ManagedAIEndpoint.current?.providerName, "Acme AI")
        XCTAssertEqual(AIProvider.managed.displayName, "Acme AI")

        UserDefaults.standard.set("ftp://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        XCTAssertNil(ManagedAIEndpoint.current, "Only HTTP and HTTPS URLs are endpoints")
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

    func testURLsInsideManagedEndpointMatch() {
        let managed = endpoint("https://ai.example.com/v1")
        for url in [
            "https://ai.example.com/v1",
            "https://ai.example.com/v1/",
            "https://ai.example.com/v1/chat/completions",
            "https://ai.example.com:443/v1",
            "https://AI.Example.COM/v1",
            " https://ai.example.com/v1 ",
        ] {
            XCTAssertTrue(CloudPolicy.isWithinManagedEndpoint(url, managedEndpoint: managed), url)
        }
    }

    func testURLsOutsideManagedEndpointDontMatch() {
        let managed = endpoint("https://ai.example.com/v1")
        for url in [
            "http://ai.example.com/v1",
            "https://ai.example.com:8443/v1",
            "https://ai.example.com/v10",
            "https://ai.example.com/v2",
            "https://ai.example.com/",
            "https://ai.example.com",
            "https://ai.example.com/v1/../admin",
            "https://ai.example.com.evil.test/v1",
            "https://evil-ai.example.com/v1",
            "https://ai.example.co/v1",
            "https://api.example.com/v1",
            "https://ai.example.com@evil.test/v1",
            "https://user@ai.example.com/v1",
            "not a url",
            "",
        ] {
            XCTAssertFalse(CloudPolicy.isWithinManagedEndpoint(url, managedEndpoint: managed), url)
        }
    }

    func testRootManagedEndpointMatchesWholeHostOnly() {
        let managed = endpoint("https://ai.example.com")
        XCTAssertTrue(CloudPolicy.isWithinManagedEndpoint("https://ai.example.com/v1", managedEndpoint: managed))
        XCTAssertFalse(CloudPolicy.isWithinManagedEndpoint("https://ai.example.com.evil.test/v1", managedEndpoint: managed))
        XCTAssertFalse(CloudPolicy.isWithinManagedEndpoint("https://ai.example.com:444/v1", managedEndpoint: managed))
    }

    func testCustomEndpointAllowedOnlyInsideManagedEndpointWhenCloudBlocked() {
        let managed = endpoint("https://ai.example.com/v1")
        func allowed(_ url: String) -> Bool {
            CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: url, cloudAllowed: false, managedEndpoint: managed)
        }

        XCTAssertTrue(allowed("https://ai.example.com/v1"))
        XCTAssertTrue(allowed("http://localhost:4000/v1"), "Loopback stays allowed")
        XCTAssertFalse(allowed("https://ai.example.com.evil.test/v1"))
        XCTAssertFalse(allowed("https://api.openai.com/v1"))
        XCTAssertFalse(
            CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: "https://ai.example.com/v1", cloudAllowed: false, managedEndpoint: nil),
            "Without a managed endpoint only loopback is allowed"
        )
        XCTAssertFalse(
            CloudPolicy.isEnhancementProviderAllowed(.openAI, cloudAllowed: false, managedEndpoint: managed),
            "A managed endpoint doesn't unblock other cloud providers"
        )
    }

    func testPlainHTTPManagedEndpointRefusedUnlessLoopback() {
        let remoteHTTP = endpoint("http://ai.example.com/v1")
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: remoteHTTP))
        XCTAssertFalse(
            CloudPolicy.isEnhancementProviderAllowed(
                .custom, customBaseURL: "http://ai.example.com/v1", cloudAllowed: false, managedEndpoint: remoteHTTP)
        )

        let loopbackHTTP = endpoint("http://localhost:4000/v1")
        XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: loopbackHTTP))

        XCTAssertTrue(
            CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: false, managedEndpoint: endpoint("https://ai.example.com/v1"))
        )
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: true, managedEndpoint: nil))
    }

    // MARK: - Requests

    func testTokenSentOnlyToManagedEndpoint() async {
        UserDefaults.standard.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        configureManagedEndpoint(token: token)
        let service = AIService()

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

    func testManagedTokenIsNotSavedToKeychain() async {
        configureManagedEndpoint(token: token)
        _ = try? await AIService().performChatCompletion(provider: .managed, modelName: nil, messages: [.user("hello")], timeout: 5)

        for name in [AIProvider.managed.rawValue, AIProvider.managed.displayName] {
            XCTAssertNil(APIKeyManager.shared.getAPIKey(forProvider: name))
        }
    }

    // MARK: - Provider selection

    func testModeWithBlockedProviderUsesManagedProvider() {
        UserDefaults.standard.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        let service = AIService()

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

    func testManagedProviderWithoutCloudBlockLeavesOtherProvidersAvailable() {
        configureManagedEndpoint("http://ai.example.com/v1")
        let service = AIService()

        XCTAssertEqual(service.connectedProviders.first, .managed)
        XCTAssertEqual(service.selectedProvider, .managed, "A new managed endpoint becomes the default")
        XCTAssertEqual(service.selectedModel(for: .managed), "org-model")
        XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.openAI))
        XCTAssertEqual(ModeRuntimeResolver.resolvedProvider(providerName: "OpenAI", aiService: service) == .managed, false)

        // The user's later choice is kept until the endpoint changes.
        service.selectedProvider = .voiceInkRefine
        service.applyManagedProviderSelection()
        XCTAssertEqual(service.selectedProvider, .voiceInkRefine)
    }

    func testManagedKeyChangesApplyWhileRunning() async {
        let service = AIService()
        XCTAssertFalse(service.connectedProviders.contains(.managed))

        await waitForPolicyChange { configureManagedEndpoint(token: token) }
        XCTAssertEqual(CloudPolicyMonitor.shared.managedEndpoint?.model, "org-model")
        XCTAssertEqual(service.connectedProviders.first, .managed)
        XCTAssertEqual(service.selectedProvider, .managed)

        await waitForPolicyChange {
            UserDefaults.standard.set("org-model-2", forKey: ManagedAIEndpoint.modelKey)
        }
        XCTAssertEqual(service.selectedModel(for: .managed), "org-model-2")

        await waitForPolicyChange {
            UserDefaults.standard.removeObject(forKey: ManagedAIEndpoint.endpointURLKey)
        }
        XCTAssertNil(CloudPolicyMonitor.shared.managedEndpoint)
        XCTAssertFalse(service.connectedProviders.contains(.managed))
        XCTAssertNotEqual(service.selectedProvider, .managed)
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
