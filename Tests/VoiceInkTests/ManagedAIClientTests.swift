import Foundation
import LLMkit
import SwiftData
import XCTest

@testable import VoiceInk

/// Answers requests from `ManagedAIClient` without a network, and records each request it sees.
final class ManagedEndpointStubProtocol: URLProtocol {
    enum Reply {
        case completion(String)
        case redirect(to: String)
        case status(Int)
    }

    struct Recorded {
        let url: URL
        let authorization: String?
        let body: [String: Any]?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    /// Replies keyed by absolute URL. Any other URL gets a 404.
    static func start(replies: [String: Reply]) {
        lock.lock()
        recorded = []
        self.replies = replies
        lock.unlock()
        ManagedAIClient.makeSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ManagedEndpointStubProtocol.self]
            return configuration
        }
    }

    static func stop() {
        ManagedAIClient.makeSessionConfiguration = { .ephemeral }
        lock.lock()
        beforeReply = nil
        lock.unlock()
    }

    /// Runs after a request arrives and before its reply is sent, to change state while the request is in flight.
    nonisolated(unsafe) static var beforeReply: (() -> Void)?

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recorded.append(
            Recorded(
                url: url,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: Self.bodyJSON(request)
            ))
        let reply = Self.replies[url.absoluteString] ?? .status(404)
        let beforeReply = Self.beforeReply
        Self.lock.unlock()
        beforeReply?()

        switch reply {
        case .completion(let text):
            let json = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
            respond(status: 200, headers: ["Content-Type": "application/json"], data: json)
        case .status(let status):
            respond(status: status, headers: [:], data: Data())
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var redirected = request
            redirected.url = URL(string: target)
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // When the session refuses the redirect, the redirect response is the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String], data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyJSON(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            var buffer = Data()
            stream.open()
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(chunk, maxLength: 4096)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
            }
            chunk.deallocate()
            stream.close()
            data = buffer
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// The request the managed provider sends, the redirect guard, and the cleanup prompt it receives.
@MainActor
final class ManagedAIClientTests: XCTestCase {
    private let token = "test-proxy-token"
    private let completionsURL = "https://ai.example.com/v1/chat/completions"
    private let preferences = TestPreferences.defaults

    override func setUp() async throws {
        try await super.setUp()
        TestPreferences.reset()
    }

    override func tearDown() async throws {
        ManagedEndpointStubProtocol.stop()
        TestPreferences.reset()
        try await super.tearDown()
    }

    private let endpoint = ManagedAIEndpoint(
        baseURL: URL(string: "https://ai.example.com/v1")!, model: "voiceink-cleanup", providerName: "Organization AI")

    private func complete(token: String? = nil) async throws -> String {
        try await ManagedAIClient.chatCompletion(
            endpoint: endpoint, token: token ?? self.token, messages: [.user("hello")], systemPrompt: "Clean it.",
            timeout: 5, maxRetries: 0)
    }

    // MARK: - Request shape

    /// LiteLLM's OpenAI-compatible API: POST to `/v1/chat/completions` with a Bearer key and the model alias.
    /// No `temperature`, because Claude Haiku 5.5 on Bedrock rejects it.
    func testRequestMatchesOpenAICompatibleProxy() async throws {
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Clean.")])

        let text = try await complete()

        XCTAssertEqual(text, "Clean.")
        let request = try XCTUnwrap(ManagedEndpointStubProtocol.requests.first)
        XCTAssertEqual(ManagedEndpointStubProtocol.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, completionsURL)
        XCTAssertEqual(request.authorization, "Bearer \(token)")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"], "Only parameters every proxy accepts")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["model"] as? String, "voiceink-cleanup")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Clean it."], ["role": "user", "content": "hello"]])
    }

    func testNoAuthorizationHeaderWithoutAToken() async throws {
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Clean.")])

        _ = try await complete(token: "")

        XCTAssertNil(ManagedEndpointStubProtocol.requests.first?.authorization)
    }

    func testProxyErrorIsReported() async {
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .status(400)])

        do {
            _ = try await complete()
            XCTFail("A 400 should throw")
        } catch {
            guard case .httpError(400, _)? = error as? LLMKitError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Redirects

    func testRedirectOutsideTheEndpointOriginIsRefused() async {
        for target in [
            "https://other.example.net/v1/chat/completions",
            "https://ai.example.com:8443/v1/chat/completions",
            "http://ai.example.com/v1/chat/completions",
            "http://ai.example.com:443/v1/chat/completions",
            "https://user@ai.example.com/v1/chat/completions",
        ] {
            ManagedEndpointStubProtocol.start(replies: [
                completionsURL: .redirect(to: target), target: .completion("Leaked."),
            ])

            do {
                let text = try await complete()
                XCTFail("Followed a redirect to \(target) and got \(text)")
            } catch {
                XCTAssertEqual(error as? ManagedAIClientError, .redirectRefused(target: target), target)
            }

            XCTAssertEqual(
                ManagedEndpointStubProtocol.requests.map(\.url.absoluteString), [completionsURL],
                "The request, and its token, went to \(target)")
        }
    }

    func testRedirectWithinTheEndpointOriginIsFollowed() async throws {
        let target = "https://ai.example.com/v2/chat/completions"
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .redirect(to: target), target: .completion("Clean.")])

        let text = try await complete()

        XCTAssertEqual(text, "Clean.")
        XCTAssertEqual(ManagedEndpointStubProtocol.requests.map(\.url.absoluteString), [completionsURL, target])
    }

    func testEndpointOrigin() {
        for url in ["https://ai.example.com/v1", "https://AI.example.com:443/other", "https://ai.example.com"] {
            XCTAssertTrue(CloudPolicy.hasManagedEndpointOrigin(URL(string: url)!, managedEndpoint: endpoint), url)
        }
        for url in [
            "http://ai.example.com/v1", "http://ai.example.com:443/v1", "https://ai.example.com:8443/v1",
            "https://ai.example.com.example.net/v1",
            "https://evil-ai.example.com/v1", "https://user:pass@ai.example.com/v1",
        ] {
            XCTAssertFalse(CloudPolicy.hasManagedEndpointOrigin(URL(string: url)!, managedEndpoint: endpoint), url)
        }
    }

    // MARK: - Cleanup prompt

    /// The managed provider gets the same Default prompt and vocabulary block as other OpenAI-compatible providers.
    func testEnhancementSendsDefaultPromptAndVocabularyToManagedEndpoint() async throws {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        preferences.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set("voiceink-cleanup", forKey: ManagedAIEndpoint.modelKey)
        preferences.set(token, forKey: ManagedAIEndpoint.tokenKey)
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Send it to the Quorvane team.")])

        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(VocabularyWord(word: "Quorvane"))
        container.mainContext.insert(VocabularyWord(word: "Jamf"))
        try container.mainContext.save()

        let prompt = try XCTUnwrap(PromptTemplates.seedPrompts.first { $0.id == PromptTemplates.defaultPromptId })
        let service = AIEnhancementService(aiService: AIService(defaultModeStore: FakeDefaultModeStore()),modelContext: container.mainContext)
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil, isEnabled: true, prompt: prompt, provider: .managed, modelName: nil,
            useClipboardContext: false, useSelectedTextContext: false, useScreenCaptureContext: false)

        let result = try await service.enhance("send it to the core vain team", configuration: configuration)

        XCTAssertEqual(result.text, "Send it to the Quorvane team.")
        let request = try XCTUnwrap(ManagedEndpointStubProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, completionsURL)
        let messages = try XCTUnwrap(request.body?["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertEqual(system, prompt.finalPromptText + "\n\n" + Self.vocabularySection("Important Vocabulary: Jamf, Quorvane"))
        XCTAssertTrue(system.contains("Clean <TRANSCRIPT> into polished, readable, general-purpose text."))
        XCTAssertEqual(messages.last?["content"], "\n<TRANSCRIPT>\nsend it to the core vain team\n</TRANSCRIPT>")
    }

    /// Opt-in check against a real OpenAI-compatible proxy, such as LiteLLM. Set `VOICEINK_PROXY_URL`,
    /// `VOICEINK_PROXY_MODEL`, and `VOICEINK_PROXY_TOKEN` (with the `TEST_RUNNER_` prefix for `xcodebuild test`).
    func testLiveProxy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["VOICEINK_PROXY_URL"], let model = environment["VOICEINK_PROXY_MODEL"] else {
            throw XCTSkip("Set VOICEINK_PROXY_URL and VOICEINK_PROXY_MODEL to run against a proxy")
        }
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        preferences.set(url, forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set(model, forKey: ManagedAIEndpoint.modelKey)
        preferences.set(environment["VOICEINK_PROXY_TOKEN"], forKey: ManagedAIEndpoint.tokenKey)

        let container = try ModelContainer(
            for: Schema([VocabularyWord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(VocabularyWord(word: "Quorvane"))
        try container.mainContext.save()
        let prompt = try XCTUnwrap(PromptTemplates.seedPrompts.first { $0.id == PromptTemplates.defaultPromptId })
        let service = AIEnhancementService(aiService: AIService(defaultModeStore: FakeDefaultModeStore()),modelContext: container.mainContext)
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil, isEnabled: true, prompt: prompt, provider: .managed, modelName: nil,
            useClipboardContext: false, useSelectedTextContext: false, useScreenCaptureContext: false)

        let result = try await service.enhance(
            "um please send the numbers to the core vain team before friday", configuration: configuration)

        XCTAssertTrue(result.text.contains("Quorvane"), result.text)
        XCTAssertFalse(result.text.lowercased().contains("um "), result.text)
    }

    private static func vocabularySection(_ vocabulary: String) -> String {
        """
        # Custom Vocabulary
        Use these custom vocabulary words, proper nouns, acronyms, product names, and technical terms as the spelling authority. When the text clearly refers to one of these entries, replace similar-sounding or phonetically close transcription mistakes with the exact spelling shown below. Do not force a replacement when the text clearly means something else:
        <CUSTOM_VOCABULARY>
        \(vocabulary)
        </CUSTOM_VOCABULARY>
        """
    }
}
