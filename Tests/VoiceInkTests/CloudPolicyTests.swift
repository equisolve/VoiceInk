import Foundation
import SwiftData
import XCTest

@testable import VoiceInk

/// Records every request that reaches the URL loading system so tests can assert none were made.
///
/// `URLProtocol.registerClass` reaches only `URLSession.shared`. LLMkit and the streaming clients create their own
/// sessions, so `start()` also adds this class to every new ephemeral and default session configuration.
final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedURLs: [URL] = []
    nonisolated(unsafe) private static var isRecording = false
    private static let installConfigurationHook: Void = {
        for name in ["ephemeralSessionConfiguration", "defaultSessionConfiguration"] {
            let original = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(name))!
            let replacement = class_getClassMethod(
                URLSessionConfiguration.self, NSSelectorFromString("recording_\(name)")
            )!
            method_exchangeImplementations(original, replacement)
        }
    }()

    static var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    static func start() {
        _ = installConfigurationHook
        lock.lock()
        recordedURLs = []
        isRecording = true
        lock.unlock()
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        lock.lock()
        isRecording = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return false }
        if let url = request.url {
            recordedURLs.append(url)
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    // After the exchange in RecordingURLProtocol, each call below runs the original Foundation method.
    @objc class func recording_ephemeralSessionConfiguration() -> URLSessionConfiguration {
        withRecordingProtocol(recording_ephemeralSessionConfiguration())
    }

    @objc class func recording_defaultSessionConfiguration() -> URLSessionConfiguration {
        withRecordingProtocol(recording_defaultSessionConfiguration())
    }

    private static func withRecordingProtocol(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.protocolClasses = [RecordingURLProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}

final class CloudPolicyTests: XCTestCase {
    private let key = CloudPolicy.disableCloudServicesKey
    private let ollamaBaseURLKey = "ollamaBaseURL"
    private var savedValue: Any?
    private var savedOllamaBaseURL: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
        savedOllamaBaseURL = UserDefaults.standard.object(forKey: ollamaBaseURLKey)
        RecordingURLProtocol.start()
    }

    override func tearDown() {
        RecordingURLProtocol.stop()
        UserDefaults.standard.set(savedValue, forKey: key)
        UserDefaults.standard.set(savedOllamaBaseURL, forKey: ollamaBaseURLKey)
        super.tearDown()
    }

    private func setOllamaBaseURL(_ url: String?) {
        UserDefaults.standard.set(url, forKey: ollamaBaseURLKey)
    }

    private func setCloudDisabled(_ disabled: Bool?) {
        if let disabled {
            UserDefaults.standard.set(disabled, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Reading the key

    func testCloudAllowedWhenKeyAbsentOrFalse() {
        setCloudDisabled(nil)
        XCTAssertTrue(CloudPolicy.isCloudAllowed)

        setCloudDisabled(false)
        XCTAssertTrue(CloudPolicy.isCloudAllowed)
    }

    func testCloudBlockedWhenKeyTrue() {
        setCloudDisabled(true)
        XCTAssertFalse(CloudPolicy.isCloudAllowed)
    }

    func testReadsKeyFromGivenDefaults() throws {
        let suiteName = "CloudPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(CloudPolicy.isCloudAllowed(in: defaults))
        defaults.set(true, forKey: key)
        XCTAssertFalse(CloudPolicy.isCloudAllowed(in: defaults))
    }

    // MARK: - Enhancement providers

    func testEveryEnhancementProviderAllowedWhenCloudAllowed() {
        for provider in AIProvider.allCases {
            XCTAssertTrue(
                CloudPolicy.isEnhancementProviderAllowed(provider, customBaseURL: "https://api.example.com/v1", cloudAllowed: true),
                "\(provider.rawValue) should be allowed when cloud services are on"
            )
        }
    }

    func testOnlyLocalEnhancementProvidersAllowedWhenCloudBlocked() {
        let allowed: Set<AIProvider> = [.ollama, .voiceInkRefine]

        for provider in AIProvider.allCases where provider != .custom {
            XCTAssertEqual(
                CloudPolicy.isEnhancementProviderAllowed(
                    provider, ollamaBaseURL: "http://localhost:11434", cloudAllowed: false),
                allowed.contains(provider),
                "Unexpected policy result for \(provider.rawValue)"
            )
        }
    }

    func testLocalCLIBlockedWhenCloudBlocked() {
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.localCLI, cloudAllowed: false))
    }

    func testCustomProviderAllowedOnlyForLoopbackHosts() {
        let loopback = [
            "http://localhost:1234/v1/chat/completions",
            "http://LOCALHOST:8080",
            "http://127.0.0.1:11434/v1",
            "https://127.0.0.1/v1",
            "http://[::1]:8000/v1/chat/completions",
            "  http://localhost:1234/v1  ",
        ]
        for url in loopback {
            XCTAssertTrue(
                CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: url, cloudAllowed: false),
                "\(url) should be allowed"
            )
        }

        let remote = [
            "https://api.openai.com/v1/chat/completions",
            "http://localhost.example.com/v1",
            "http://127.0.0.1.nip.io/v1",
            "http://127.0.0.2/v1",
            "http://192.168.1.10:1234/v1",
            "http://0.0.0.0:1234/v1",
            "localhost:1234",
            "",
        ]
        for url in remote {
            XCTAssertFalse(
                CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: url, cloudAllowed: false),
                "\(url) should be blocked"
            )
        }

        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: nil, cloudAllowed: false))
    }

    func testRequireEnhancementThrowsPolicyError() {
        XCTAssertThrowsError(try CloudPolicy.requireEnhancementProviderAllowed(.openAI, cloudAllowed: false)) { error in
            XCTAssertEqual(error as? CloudPolicyError, .cloudEnhancementDisabled(providerName: AIProvider.openAI.rawValue))
        }
        XCTAssertNoThrow(
            try CloudPolicy.requireEnhancementProviderAllowed(
                .ollama, ollamaBaseURL: "http://localhost:11434", cloudAllowed: false))
    }

    func testOllamaAllowedOnlyForLoopbackHosts() {
        for url in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            XCTAssertTrue(
                CloudPolicy.isEnhancementProviderAllowed(.ollama, ollamaBaseURL: url, cloudAllowed: false),
                "\(url) should be allowed"
            )
        }
        for url in ["http://192.168.1.10:11434", "https://ollama.example.com", "http://localhost.example.com:11434", ""] {
            XCTAssertFalse(
                CloudPolicy.isEnhancementProviderAllowed(.ollama, ollamaBaseURL: url, cloudAllowed: false),
                "\(url) should be blocked"
            )
            XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.ollama, ollamaBaseURL: url, cloudAllowed: true))
        }
    }

    func testOllamaCheckedAgainstSavedServerURL() {
        setOllamaBaseURL("http://192.168.1.10:11434")
        XCTAssertFalse(CloudPolicy.isEnhancementProviderAllowed(.ollama, cloudAllowed: false))

        setOllamaBaseURL(nil)
        XCTAssertTrue(CloudPolicy.isEnhancementProviderAllowed(.ollama, cloudAllowed: false))
    }

    // MARK: - Transcription models

    func testOnlyLocalTranscriptionProvidersAllowedWhenCloudBlocked() {
        let local: Set<ModelProvider> = [.whisper, .fluidAudio, .transcribeCpp, .nativeApple]

        for provider in ModelProvider.allCases {
            XCTAssertEqual(
                CloudPolicy.isTranscriptionAllowed(provider, cloudAllowed: false),
                local.contains(provider),
                "Unexpected policy result for \(provider.rawValue)"
            )
            XCTAssertTrue(CloudPolicy.isTranscriptionAllowed(provider, cloudAllowed: true))
        }
    }

    func testTranscriptionModelFiltering() {
        let models = TranscriptionModelRegistry.models
        XCTAssertTrue(models.contains { !CloudPolicy.isLocalTranscriptionProvider($0.provider) }, "Registry should list cloud models")

        let filtered = CloudPolicy.allowedTranscriptionModels(models, cloudAllowed: false)
        XCTAssertFalse(filtered.isEmpty)
        XCTAssertTrue(filtered.allSatisfy { CloudPolicy.isLocalTranscriptionProvider($0.provider) })
        XCTAssertEqual(
            filtered.count,
            models.filter { CloudPolicy.isLocalTranscriptionProvider($0.provider) }.count
        )

        XCTAssertEqual(CloudPolicy.allowedTranscriptionModels(models, cloudAllowed: true).count, models.count)
    }

    // MARK: - Requests fail before any network call

    @MainActor
    func testCloudEnhancementRequestThrowsBeforeNetworking() async {
        setCloudDisabled(true)
        let service = AIService()

        for provider in [AIProvider.openAI, .anthropic, .gemini, .groq, .openRouter, .localCLI] {
            do {
                _ = try await service.performChatCompletion(
                    provider: provider,
                    modelName: "test-model",
                    messages: [.user("hello")]
                )
                XCTFail("\(provider.rawValue) request should have been refused")
            } catch {
                XCTAssertEqual(
                    error as? CloudPolicyError,
                    .cloudEnhancementDisabled(providerName: provider.rawValue),
                    "\(provider.rawValue) should fail on policy, not later: \(error)"
                )
            }
        }

        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }

    @MainActor
    func testRemoteOllamaRefusedBeforeNetworking() async {
        setCloudDisabled(true)
        setOllamaBaseURL("http://192.168.1.10:11434")

        do {
            _ = try await AIService().performChatCompletion(
                provider: .ollama,
                modelName: "llama3",
                messages: [.user("hello")]
            )
            XCTFail("Chat request to a remote Ollama server should have been refused")
        } catch {
            XCTAssertEqual(error as? CloudPolicyError, .cloudEnhancementDisabled(providerName: "Ollama"), "\(error)")
        }

        let ollama = OllamaService()
        do {
            _ = try await ollama.enhance("hello", withSystemPrompt: "Clean up the text.", model: "llama3")
            XCTFail("Generate request to a remote Ollama server should have been refused")
        } catch {
            XCTAssertEqual(error as? CloudPolicyError, .cloudEnhancementDisabled(providerName: "Ollama"), "\(error)")
        }

        let listing = await ollama.refreshConnectionAndModels()
        if case .failure(let error) = listing {
            XCTAssertEqual(error as? CloudPolicyError, .cloudEndpointDisabled)
        } else {
            XCTFail("Model listing on a remote Ollama server should have been refused")
        }

        await ollama.checkConnection()
        XCTAssertFalse(ollama.isConnected)

        let verification = await AIService().verifyAPIKey("", for: .ollama)
        XCTAssertFalse(verification.isValid)

        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }

    @MainActor
    func testLoopbackOllamaPassesPolicy() async {
        setCloudDisabled(true)
        // Nothing listens on loopback port 9, so the request fails fast after passing the policy check.
        setOllamaBaseURL("http://127.0.0.1:9")

        do {
            _ = try await OllamaService().enhance(
                "hello", withSystemPrompt: "Clean up the text.", model: "llama3", timeout: 5)
            XCTFail("Nothing listens on port 9, so the request should fail")
        } catch {
            XCTAssertNil(error as? CloudPolicyError, "Loopback Ollama should pass the policy check: \(error)")
        }
        // LLMkit sends this through its own ephemeral session, so this also proves the recorder sees that traffic.
        XCTAssertTrue(RecordingURLProtocol.requests.contains { $0.host == "127.0.0.1" }, "\(RecordingURLProtocol.requests)")

        let verification = await AIService().verifyAPIKey("", for: .ollama)
        XCTAssertTrue(verification.isValid)
    }

    /// Adds a custom provider for one test and removes it, with its API key, afterward. The key goes to the
    /// in-memory credential store that unit tests use, never the login Keychain.
    @MainActor
    private func withCustomProvider(baseURL: String, _ body: (String) async throws -> Void) async rethrows {
        guard KeychainService.shared.usesMemoryStore else {
            XCTFail("The test host must store credentials in memory")
            return
        }
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

    @MainActor
    func testRemoteCustomEndpointRefusedBeforeNetworking() async {
        setCloudDisabled(true)

        await withCustomProvider(baseURL: "https://llm.example.com/v1") { model in
            do {
                _ = try await AIService().performChatCompletion(provider: .custom, modelName: model, messages: [.user("hello")])
                XCTFail("Request to a remote custom endpoint should have been refused")
            } catch {
                XCTAssertEqual(error as? CloudPolicyError, .cloudEnhancementDisabled(providerName: "Custom"), "\(error)")
            }
        }

        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }

    @MainActor
    func testLoopbackCustomEndpointPassesPolicy() async {
        setCloudDisabled(true)

        await withCustomProvider(baseURL: "http://127.0.0.1:9/v1") { model in
            do {
                _ = try await AIService().performChatCompletion(
                    provider: .custom, modelName: model, messages: [.user("hello")], timeout: 5)
                XCTFail("Nothing listens on port 9, so the request should fail")
            } catch {
                XCTAssertNil(error as? CloudPolicyError, "Loopback custom endpoint should pass the policy check: \(error)")
            }
        }

        XCTAssertTrue(RecordingURLProtocol.requests.contains { $0.host == "127.0.0.1" }, "\(RecordingURLProtocol.requests)")
    }

    @MainActor
    func testCloudTranscriptionRequestThrowsBeforeNetworking() async throws {
        setCloudDisabled(true)
        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = CloudTranscriptionService(modelContext: container.mainContext)
        let missingAudio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        let cloudModels = TranscriptionModelRegistry.models.filter {
            !CloudPolicy.isLocalTranscriptionProvider($0.provider)
        }
        XCTAssertFalse(cloudModels.isEmpty)

        for model in cloudModels {
            do {
                _ = try await service.transcribe(
                    audioURL: missingAudio,
                    model: model,
                    context: TranscriptionRequestContext(language: "en", prompt: nil)
                )
                XCTFail("\(model.name) request should have been refused")
            } catch {
                // A missing-file error here would mean the policy check ran too late.
                XCTAssertEqual(error as? CloudPolicyError, .cloudTranscriptionDisabled, "\(model.name): \(error)")
            }
        }

        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }

    @MainActor
    func testCloudStreamingRequestThrowsBeforeNetworking() async throws {
        setCloudDisabled(true)
        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = try XCTUnwrap(
            TranscriptionModelRegistry.models.first { $0.supportsStreaming && !CloudPolicy.isLocalTranscriptionProvider($0.provider) }
        )
        let service = StreamingTranscriptionService(modelContext: container.mainContext)

        do {
            try await service.startStreaming(model: model, context: TranscriptionRequestContext(language: "en", prompt: nil))
            XCTFail("Streaming to \(model.name) should have been refused")
        } catch {
            XCTAssertEqual(error as? CloudPolicyError, .cloudTranscriptionDisabled)
        }

        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }

    @MainActor
    func testEnhancementKeyVerificationRefusedWhenCloudBlocked() async {
        setCloudDisabled(true)
        let result = await AIService().verifyAPIKey("sk-test", for: .openAI)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errorMessage, CloudPolicyError.cloudEnhancementDisabled(providerName: "OpenAI").errorDescription)
        XCTAssertEqual(RecordingURLProtocol.requests, [])
    }
}
