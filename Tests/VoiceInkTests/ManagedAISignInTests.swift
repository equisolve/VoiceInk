import Foundation
import LLMkit
import XCTest

@testable import VoiceInk

/// Answers the sign-in server's token and key requests without a network, and records each request it sees.
final class SignInServerStubProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let json: [String: Any]
    }

    struct Recorded {
        let method: String
        let url: URL
        let authorization: String?
        let contentType: String?
        let body: String
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
        ManagedAISignInClient.makeSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SignInServerStubProtocol.self]
            return configuration
        }
    }

    static func stop() {
        ManagedAISignInClient.makeSessionConfiguration = { .ephemeral }
    }

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
                method: request.httpMethod ?? "GET",
                url: url,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: Self.body(request)
            ))
        let reply = Self.replies[url.absoluteString] ?? Reply(status: 404, json: [:])
        Self.lock.unlock()

        let data = try! JSONSerialization.data(withJSONObject: reply.json)
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
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
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Signing in with Equisolve: PKCE, the browser callback, the token and key requests, which credential a request
/// sends, and what a 401 does.
@MainActor
final class ManagedAISignInTests: XCTestCase {
    private let signInURL = URL(string: "https://hourglass.example.com")!
    private let tokenURL = "https://hourglass.example.com/oauth/token"
    private let keyURL = "https://hourglass.example.com/api/voiceink/key"
    private let completionsURL = "https://ai.example.com/v1/chat/completions"
    private let preferences = TestPreferences.defaults
    private var keyStore: ManagedAIKeyStore!

    override func setUp() async throws {
        try await super.setUp()
        TestPreferences.reset()
        keyStore = ManagedAIKeyStore(keychain: KeychainService(memoryStore: InMemoryCredentialStore()))
    }

    override func tearDown() async throws {
        SignInServerStubProtocol.stop()
        ManagedEndpointStubProtocol.stop()
        TestPreferences.reset()
        try await super.tearDown()
    }

    // MARK: - PKCE

    /// The example in RFC 7636, appendix B.
    func testPKCEChallengeMatchesRFC7636Example() {
        XCTAssertEqual(
            ManagedAISignInClient.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsRandomAndUsesOnlyUnreservedCharacters() {
        let first = ManagedAISignInClient.PKCE.generate()
        let second = ManagedAISignInClient.PKCE.generate()

        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.verifier.count, 43, "32 bytes, base64url without padding")
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        XCTAssertTrue(first.verifier.unicodeScalars.allSatisfy(unreserved.contains))
        XCTAssertEqual(first.challenge, ManagedAISignInClient.PKCE.challenge(for: first.verifier))
    }

    func testAuthorizeURL() throws {
        let url = ManagedAISignInClient.authorizeURL(
            signInURL: signInURL, redirectURI: "http://127.0.0.1:50000/oauth/callback", state: "s1",
            codeChallenge: "c1")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "hourglass.example.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(
            query,
            [
                "response_type": "code", "client_id": "voiceink-mac", "scope": "voiceink", "state": "s1",
                "redirect_uri": "http://127.0.0.1:50000/oauth/callback", "code_challenge": "c1",
                "code_challenge_method": "S256",
            ])
    }

    func testPathsKeepASignInURLPath() {
        let url = URL(string: "https://example.com/hourglass/")!
        XCTAssertEqual(
            ManagedAISignInClient.endpoint("oauth/token", under: url).absoluteString,
            "https://example.com/hourglass/oauth/token")
    }

    // MARK: - Callback

    func testCallbackReturnsTheCode() throws {
        XCTAssertEqual(
            try ManagedAISignInClient.authorizationCode(
                fromCallbackTarget: "/oauth/callback?code=abc%2F1&state=s1", expectedState: "s1"),
            "abc/1")
    }

    func testCallbackWithAnotherStateIsRefused() {
        for target in [
            "/oauth/callback?code=abc&state=other",
            "/oauth/callback?code=abc",
            "/oauth/callback?code=abc&state=",
            "/oauth/callback?error=access_denied&state=other",
        ] {
            XCTAssertThrowsError(
                try ManagedAISignInClient.authorizationCode(fromCallbackTarget: target, expectedState: "s1"), target
            ) { error in
                XCTAssertEqual(error as? ManagedAISignInError, .stateMismatch, target)
            }
        }
    }

    func testCallbackErrors() {
        let cases: [(String, ManagedAISignInError)] = [
            ("/oauth/callback?error=access_denied&state=s1", .authorizationDenied),
            ("/oauth/callback?error=invalid_scope&state=s1", .authorizationFailed("invalid_scope")),
            ("/oauth/callback?state=s1", .invalidResponse),
            ("/other?code=abc&state=s1", .invalidResponse),
        ]
        for (target, expected) in cases {
            XCTAssertThrowsError(
                try ManagedAISignInClient.authorizationCode(fromCallbackTarget: target, expectedState: "s1"), target
            ) { error in
                XCTAssertEqual(error as? ManagedAISignInError, expected, target)
            }
        }
    }

    func testRequestTargetParsing() {
        XCTAssertEqual(
            OAuthLoopbackListener.requestTarget(
                in: Data("GET /oauth/callback?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)),
            "/oauth/callback?code=a&state=b")
        XCTAssertNil(OAuthLoopbackListener.requestTarget(in: Data("GET /oauth/callback HTTP/1.1\r\nHost: x".utf8)))
        XCTAssertNil(OAuthLoopbackListener.requestTarget(in: Data("POST /oauth/callback HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(
            OAuthLoopbackListener.requestTarget(in: Data("GET http://evil.example/ HTTP/1.1\r\n\r\n".utf8)))
    }

    func testLoopbackListenerAnswersTheCallbackAndIgnoresOtherPaths() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 30)
        let port = try await listener.start()
        defer { listener.cancel() }

        let session = URLSession(configuration: .ephemeral)
        let (_, faviconResponse) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((faviconResponse as? HTTPURLResponse)?.statusCode, 404)

        let (page, response) = try await session.data(
            from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=abc&state=s1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("You can close this tab"))

        let target = try await listener.waitForCallback()
        XCTAssertEqual(target, "/oauth/callback?code=abc&state=s1")
    }

    /// Another program that finds the port can't end the sign-in by sending a callback without the right state.
    func testLoopbackListenerKeepsWaitingAfterAnotherState() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 30)
        let port = try await listener.start()
        defer { listener.cancel() }

        let session = URLSession(configuration: .ephemeral)
        for query in ["code=forged&state=other", "error=access_denied&state=other", "code=forged"] {
            let (_, response) = try await session.data(
                from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?\(query)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400, query)
        }

        let (_, response) = try await session.data(
            from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=abc&state=s1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let target = try await listener.waitForCallback()
        XCTAssertEqual(target, "/oauth/callback?code=abc&state=s1")
    }

    /// An error with the right state still ends the wait, so the person sees why sign-in failed.
    func testLoopbackListenerReturnsAnErrorWithTheRightState() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 30)
        let port = try await listener.start()
        defer { listener.cancel() }

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?error=access_denied&state=s1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let target = try await listener.waitForCallback()
        XCTAssertThrowsError(
            try ManagedAISignInClient.authorizationCode(fromCallbackTarget: target, expectedState: "s1")
        ) { XCTAssertEqual($0 as? ManagedAISignInError, .authorizationDenied) }
    }

    func testLoopbackListenerTimesOut() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 0.2)
        _ = try await listener.start()

        do {
            _ = try await listener.waitForCallback()
            XCTFail("Waiting should time out")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .timedOut)
        }
    }

    func testCancelingTheWaitStopsTheListener() async throws {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 30)
        let port = try await listener.start()

        let wait = Task { try await listener.waitForCallback() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let canceledAt = Date()
        wait.cancel()

        do {
            _ = try await wait.value
            XCTFail("Waiting should be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(canceledAt), 2)

        let session = URLSession(configuration: .ephemeral)
        do {
            _ = try await session.data(
                from: URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=abc&state=s1")!)
            XCTFail("The listener should be closed")
        } catch {}
    }

    func testCancelingBeforeStartFailsTheStart() async {
        let listener = OAuthLoopbackListener(callbackPath: "/oauth/callback", expectedState: "s1", timeout: 30)
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await listener.start()
        }

        do {
            _ = try await start.value
            XCTFail("Starting should be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    /// Cancel in the settings ends the whole sign-in promptly while VoiceInk waits for the browser.
    func testCancelingSignInEndsItPromptly() async throws {
        var opened = false
        let signIn = Task { @MainActor [signInURL] in
            try await ManagedAISignInClient.signIn(signInURL: signInURL, callbackTimeout: 30) { _ in
                opened = true
                return true
            }
        }
        while !opened {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let canceledAt = Date()
        signIn.cancel()

        do {
            _ = try await signIn.value
            XCTFail("Sign-in should be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(canceledAt), 2)
    }

    // MARK: - Token and key requests

    func testSignInExchangesTheCodeAndReturnsTheKey() async throws {
        SignInServerStubProtocol.start(replies: [
            tokenURL: .init(status: 200, json: ["access_token": "hourglass-access", "token_type": "Bearer"]),
            keyURL: .init(status: 200, json: ["api_key": "sk-person", "key_alias": "pat@example.com"]),
        ])
        var openedURL: URL?

        let key = try await ManagedAISignInClient.signIn(signInURL: signInURL, callbackTimeout: 30) { url in
            openedURL = url
            Self.completeInBrowser(authorizeURL: url, code: "the-code")
            return true
        }

        XCTAssertEqual(key, ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))

        let authorize = try XCTUnwrap(openedURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let query = Dictionary(uniqueKeysWithValues: (authorize.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        XCTAssertTrue(redirectURI.hasPrefix("http://127.0.0.1:"), redirectURI)
        XCTAssertTrue(redirectURI.hasSuffix("/oauth/callback"), redirectURI)

        let requests = SignInServerStubProtocol.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), [tokenURL, keyURL])

        let tokenRequest = requests[0]
        XCTAssertEqual(tokenRequest.method, "POST")
        XCTAssertEqual(tokenRequest.contentType, "application/x-www-form-urlencoded")
        XCTAssertNil(tokenRequest.authorization)
        let form = Self.formFields(tokenRequest.body)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "the-code")
        XCTAssertEqual(form["redirect_uri"], redirectURI)
        XCTAssertEqual(form["client_id"], "voiceink-mac")
        let verifier = try XCTUnwrap(form["code_verifier"])
        XCTAssertEqual(ManagedAISignInClient.PKCE.challenge(for: verifier), query["code_challenge"])

        XCTAssertEqual(requests[1].method, "POST")
        XCTAssertEqual(requests[1].authorization, "Bearer hourglass-access")
    }

    func testDeactivatedAccountIsReported() async {
        SignInServerStubProtocol.start(replies: [keyURL: .init(status: 403, json: ["error": "deactivated"])])

        do {
            _ = try await ManagedAISignInClient.fetchKey(accessToken: "hourglass-access", signInURL: signInURL)
            XCTFail("A 403 should throw")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .accountDeactivated)
        }
    }

    func testFailedTokenExchangeIsReported() async {
        SignInServerStubProtocol.start(replies: [tokenURL: .init(status: 400, json: ["error": "invalid_grant"])])

        do {
            _ = try await ManagedAISignInClient.exchangeCode(
                "code", codeVerifier: "verifier", redirectURI: "http://127.0.0.1:1/oauth/callback",
                signInURL: signInURL)
            XCTFail("A 400 should throw")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .serverError(statusCode: 400))
        }
    }

    // MARK: - URL validation and policy

    func testSignInURLValidation() {
        for url in ["https://hourglass.example.com", "https://hourglass.example.com/base/", "https://h.example:8443"] {
            XCTAssertTrue(ManagedAIEndpoint.isValidSignInURL(URL(string: url)!), url)
        }
        for url in [
            "http://hourglass.example.com", "https://user:pass@hourglass.example.com",
            "https://hourglass.example.com/?next=x", "https://hourglass.example.com/#f", "ftp://hourglass.example.com",
        ] {
            XCTAssertFalse(ManagedAIEndpoint.isValidSignInURL(URL(string: url)!), url)
        }
    }

    func testSignInURLIsReadWithTheEndpoint() {
        preferences.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        XCTAssertNil(ManagedAIEndpoint.current?.signInURL)

        preferences.set(" https://hourglass.example.com ", forKey: ManagedAIEndpoint.signInURLKey)
        XCTAssertEqual(ManagedAIEndpoint.current?.signInURL, signInURL)

        preferences.set("http://hourglass.example.com", forKey: ManagedAIEndpoint.signInURLKey)
        XCTAssertNil(ManagedAIEndpoint.current?.signInURL, "Sign-in needs HTTPS")
        XCTAssertNotNil(ManagedAIEndpoint.current, "An invalid sign-in URL doesn't turn off the endpoint")
    }

    func testSignInChangesApplyWhileRunning() async {
        CloudPolicyMonitor.shared.start()
        preferences.set("https://ai.example.com/v1", forKey: ManagedAIEndpoint.endpointURLKey)
        preferences.set("org-model", forKey: ManagedAIEndpoint.modelKey)
        CloudPolicyMonitor.shared.refresh()
        XCTAssertNil(CloudPolicyMonitor.shared.managedEndpoint?.signInURL)

        let changed = expectation(forNotification: .cloudPolicyDidChange, object: nil)
        preferences.set(signInURL.absoluteString, forKey: ManagedAIEndpoint.signInURLKey)
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertEqual(CloudPolicyMonitor.shared.managedEndpoint?.signInURL, signInURL)
    }

    /// Sign-in goes only to the organization's own server, so it's allowed with cloud services off, and only there.
    func testSignInRequestsStayOnTheSignInServer() {
        preferences.set(true, forKey: CloudPolicy.disableCloudServicesKey)
        for url in ["https://hourglass.example.com/oauth/token", "https://HOURGLASS.example.com:443/api/voiceink/key"] {
            XCTAssertTrue(CloudPolicy.isManagedSignInRequestAllowed(URL(string: url)!, signInURL: signInURL), url)
        }
        for url in [
            "http://hourglass.example.com/oauth/token", "https://other.example.com/oauth/token",
            "https://hourglass.example.com:8443/oauth/token", "https://user@hourglass.example.com/oauth/token",
        ] {
            XCTAssertFalse(CloudPolicy.isManagedSignInRequestAllowed(URL(string: url)!, signInURL: signInURL), url)
        }
        XCTAssertFalse(
            CloudPolicy.isManagedSignInRequestAllowed(
                URL(string: "http://hourglass.example.com/oauth/token")!,
                signInURL: URL(string: "http://hourglass.example.com")!),
            "An HTTP sign-in URL is never allowed")
    }

    // MARK: - Which credential a request sends

    func testCredentialPrecedence() {
        XCTAssertEqual(
            ManagedAICredential.resolve(profileToken: "profile", signInConfigured: true, signedInKey: "sk-person"),
            .profileToken("profile"))
        XCTAssertEqual(
            ManagedAICredential.resolve(profileToken: "", signInConfigured: true, signedInKey: "sk-person"),
            .signedInKey("sk-person"))
        XCTAssertEqual(
            ManagedAICredential.resolve(profileToken: "", signInConfigured: true, signedInKey: nil), .signInRequired)
        XCTAssertEqual(
            ManagedAICredential.resolve(profileToken: "", signInConfigured: false, signedInKey: "sk-person"), .none,
            "A saved key isn't sent once sign-in is removed from the profile")
        XCTAssertEqual(ManagedAICredential.resolve(profileToken: "", signInConfigured: false, signedInKey: nil), .none)
        XCTAssertEqual(
            ManagedAICredential.resolve(profileToken: "profile", signInConfigured: false, signedInKey: nil),
            .profileToken("profile"))
    }

    func testSignedInKeyIsSent() async throws {
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Clean.")])

        let text = try await complete()

        XCTAssertEqual(text, "Clean.")
        XCTAssertEqual(ManagedEndpointStubProtocol.requests.first?.authorization, "Bearer sk-person")
    }

    func testProfileTokenWinsOverSignedInKey() async throws {
        preferences.set("profile-token", forKey: ManagedAIEndpoint.tokenKey)
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Clean.")])

        _ = try await complete()

        XCTAssertEqual(ManagedEndpointStubProtocol.requests.first?.authorization, "Bearer profile-token")
    }

    func testNothingIsSentBeforeSigningIn() async {
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .completion("Clean.")])

        do {
            _ = try await complete()
            XCTFail("Should ask the person to sign in")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .notSignedIn)
            XCTAssertEqual(error.localizedDescription, "Sign in with Equisolve to use AI cleanup.")
        }
        XCTAssertTrue(ManagedEndpointStubProtocol.requests.isEmpty)
    }

    // MARK: - 401

    func testUnauthorizedSignedInKeyIsDeleted() async {
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-revoked", keyAlias: "pat@example.com"))
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .status(401)])

        do {
            _ = try await complete()
            XCTFail("A 401 should throw")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .signInExpired)
        }
        XCTAssertNil(keyStore.load(), "The rejected key is deleted")
    }

    /// When the person signs in again while a request with the old key is running, the 401 for the old key leaves the
    /// new key in place.
    func testUnauthorizedOldKeyKeepsANewerKey() async {
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-old", keyAlias: "pat@example.com"))
        let newKey = ManagedAISignedInKey(apiKey: "sk-new", keyAlias: "pat@example.com")
        let store = keyStore!
        ManagedEndpointStubProtocol.beforeReply = { store.save(newKey) }
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .status(401)])

        do {
            _ = try await complete()
            XCTFail("A 401 should throw")
        } catch {
            XCTAssertEqual(error as? ManagedAISignInError, .signInExpired)
        }
        XCTAssertEqual(ManagedEndpointStubProtocol.requests.first?.authorization, "Bearer sk-old")
        XCTAssertEqual(keyStore.load(), newKey, "The newer key stays")
    }

    func testUnauthorizedProfileTokenKeepsSignedInKey() async {
        preferences.set("profile-token", forKey: ManagedAIEndpoint.tokenKey)
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .status(401)])

        do {
            _ = try await complete()
            XCTFail("A 401 should throw")
        } catch {
            guard case .httpError(401, _)? = error as? LLMKitError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNotNil(keyStore.load(), "The signed-in key wasn't the one rejected")
    }

    func testOtherErrorsKeepSignedInKey() async {
        keyStore.save(ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))
        ManagedEndpointStubProtocol.start(replies: [completionsURL: .status(403)])

        do {
            _ = try await complete()
            XCTFail("A 403 should throw")
        } catch {}
        XCTAssertNotNil(keyStore.load())
    }

    // MARK: - Key store

    func testKeyStoreRoundTripsAndNeverSyncs() {
        let memory = InMemoryCredentialStore()
        let store = ManagedAIKeyStore(keychain: KeychainService(memoryStore: memory))
        XCTAssertNil(store.load())

        XCTAssertTrue(store.save(ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com")))
        XCTAssertEqual(store.load(), ManagedAISignedInKey(apiKey: "sk-person", keyAlias: "pat@example.com"))
        XCTAssertEqual(memory.allValues.count, 1, "One Keychain item holds the key and the account name")

        XCTAssertTrue(store.delete())
        XCTAssertNil(store.load())
    }

    // MARK: - Helpers

    private func complete() async throws -> String {
        let endpoint = ManagedAIEndpoint(
            baseURL: URL(string: "https://ai.example.com/v1")!, model: "org-model", providerName: "Organization AI",
            signInURL: signInURL)
        return try await ManagedAIClient.chatCompletion(
            endpoint: endpoint, messages: [.user("hello")], systemPrompt: nil, timeout: 5, defaults: preferences,
            keyStore: keyStore, maxRetries: 0)
    }

    /// Does what the browser does after the person signs in: requests the redirect URI with a code and the state.
    private nonisolated static func completeInBrowser(authorizeURL: URL, code: String) {
        let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirectURI = items.first { $0.name == "redirect_uri" }?.value ?? ""
        let state = items.first { $0.name == "state" }?.value ?? ""
        var callback = URLComponents(string: redirectURI)!
        callback.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
        let url = callback.url!
        Task.detached {
            _ = try? await URLSession(configuration: .ephemeral).data(from: url)
        }
    }

    private static func formFields(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }
}
