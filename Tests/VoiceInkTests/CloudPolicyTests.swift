import Foundation
import SwiftData
import XCTest

@testable import VoiceInk

/// Records every request that reaches the URL loading system so tests can assert none were made.
final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedURLs: [URL] = []

    static var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    static func reset() {
        lock.lock()
        recordedURLs = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        if let url = request.url {
            lock.lock()
            recordedURLs.append(url)
            lock.unlock()
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

final class CloudPolicyTests: XCTestCase {
    private let key = CloudPolicy.disableCloudServicesKey
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
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
                CloudPolicy.isEnhancementProviderAllowed(provider, cloudAllowed: false),
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
        XCTAssertNoThrow(try CloudPolicy.requireEnhancementProviderAllowed(.ollama, cloudAllowed: false))
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
