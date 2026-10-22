import CryptoKit
import Foundation
import os

/// Signs a person in with Equisolve to get their own key for the organization AI endpoint.
///
/// This is the OAuth 2.0 authorization code flow for a public client with S256 PKCE (RFC 7636), using the default
/// browser and a loopback redirect (RFC 8252):
///
/// 1. Open `<ManagedAISignInURL>/oauth/authorize` in the default browser, with a random `state` and a PKCE challenge.
/// 2. Receive the redirect on `http://127.0.0.1:<port>/oauth/callback` and check `state`.
/// 3. `POST <ManagedAISignInURL>/oauth/token` to trade the code and PKCE verifier for an access token.
/// 4. `POST <ManagedAISignInURL>/api/voiceink/key` with that token to get the person's key and account name.
///
/// The access token is used only for step 4 and is then dropped. It's never saved or logged. Requests follow
/// redirects only within the sign-in server's scheme, host, and port.
enum ManagedAISignInClient {
    static let clientID = "voiceink-mac"
    static let scope = "voiceink"
    static let callbackPath = "/oauth/callback"
    /// How long to wait for the browser to come back before giving up.
    static let callbackTimeout: TimeInterval = 300

    /// Makes the configuration for each request's session. Tests replace it to add a stub protocol.
    static var makeSessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedAISignIn")

    // MARK: - Sign-in

    /// Runs the whole flow and returns the key. The caller saves it.
    ///
    /// - Parameter openInBrowser: Opens the authorize URL in the default browser and returns false when it can't.
    static func signIn(
        signInURL: URL,
        callbackTimeout: TimeInterval = callbackTimeout,
        openInBrowser: @MainActor (URL) -> Bool
    ) async throws -> ManagedAISignedInKey {
        guard ManagedAIEndpoint.isValidSignInURL(signInURL) else { throw ManagedAISignInError.invalidResponse }

        let pkce = PKCE.generate()
        let state = randomURLSafeString(byteCount: 32)
        let listener = OAuthLoopbackListener(callbackPath: callbackPath, timeout: callbackTimeout)
        defer { listener.cancel() }

        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)\(callbackPath)"
        let authorizeURL = authorizeURL(
            signInURL: signInURL, redirectURI: redirectURI, state: state, codeChallenge: pkce.challenge)

        guard await openInBrowser(authorizeURL) else { throw ManagedAISignInError.browserUnavailable }

        let target = try await listener.waitForCallback()
        let code = try authorizationCode(fromCallbackTarget: target, expectedState: state)
        let accessToken = try await exchangeCode(
            code, codeVerifier: pkce.verifier, redirectURI: redirectURI, signInURL: signInURL)
        return try await fetchKey(accessToken: accessToken, signInURL: signInURL)
    }

    // MARK: - PKCE

    struct PKCE: Equatable {
        let verifier: String
        let challenge: String

        /// A verifier of 43 characters from 32 random bytes, as RFC 7636 section 4.1 recommends.
        static func generate() -> PKCE {
            let verifier = ManagedAISignInClient.randomURLSafeString(byteCount: 32)
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        /// `BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`, the S256 method.
        static func challenge(for verifier: String) -> String {
            ManagedAISignInClient.base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URLEncoded(Data(bytes))
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization request and callback

    static func authorizeURL(signInURL: URL, redirectURI: String, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(
            url: endpoint("oauth/authorize", under: signInURL), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The code from the redirect's query, after checking that `state` matches the one VoiceInk sent.
    static func authorizationCode(fromCallbackTarget target: String, expectedState: String) throws -> String {
        guard let components = URLComponents(string: target), components.path == callbackPath else {
            throw ManagedAISignInError.invalidResponse
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let state = value("state"), state == expectedState else {
            throw ManagedAISignInError.stateMismatch
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? ManagedAISignInError.authorizationDenied : ManagedAISignInError.authorizationFailed(error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ManagedAISignInError.invalidResponse
        }
        return code
    }

    // MARK: - Token and key requests

    /// Trades the authorization code for an access token at `<ManagedAISignInURL>/oauth/token`.
    static func exchangeCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: String,
        signInURL: URL
    ) async throws -> String {
        var request = URLRequest(url: endpoint("oauth/token", under: signInURL))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            formEncoded([
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI),
                ("client_id", clientID),
                ("code_verifier", codeVerifier),
            ]).utf8)

        struct TokenResponse: Decodable {
            let access_token: String
        }

        let data = try await send(request, signInURL: signInURL)
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data).access_token, !token.isEmpty else {
            throw ManagedAISignInError.invalidResponse
        }
        return token
    }

    /// Gets the person's key from `<ManagedAISignInURL>/api/voiceink/key`. A 403 means the account is deactivated.
    static func fetchKey(accessToken: String, signInURL: URL) async throws -> ManagedAISignedInKey {
        var request = URLRequest(url: endpoint("api/voiceink/key", under: signInURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request, signInURL: signInURL)
        guard let key = try? JSONDecoder().decode(ManagedAISignedInKey.self, from: data),
            !key.apiKey.isEmpty
        else {
            throw ManagedAISignInError.invalidResponse
        }
        return key
    }

    private static func send(_ request: URLRequest, signInURL: URL) async throws -> Data {
        guard let url = request.url, CloudPolicy.isManagedSignInRequestAllowed(url, signInURL: signInURL) else {
            throw ManagedAISignInError.invalidResponse
        }
        var request = request
        request.timeoutInterval = 30
        let configuration = makeSessionConfiguration()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil

        let session = URLSession(
            configuration: configuration,
            delegate: ManagedSignInRedirectGuard(signInURL: signInURL),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            logger.error("A sign-in request failed: \(error.localizedDescription, privacy: .public)")
            throw ManagedAISignInError.networkError
        }

        guard let http = response as? HTTPURLResponse else { throw ManagedAISignInError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 403 where request.url?.path.hasSuffix("/api/voiceink/key") == true:
            throw ManagedAISignInError.accountDeactivated
        default:
            logger.error(
                "The sign-in server returned HTTP \(http.statusCode, privacy: .public) for \(request.url?.path ?? "", privacy: .public)"
            )
            throw ManagedAISignInError.serverError(statusCode: http.statusCode)
        }
    }

    // MARK: - Helpers

    /// A path under the sign-in URL, which may itself have a path.
    static func endpoint(_ path: String, under signInURL: URL) -> URL {
        path.split(separator: "/").reduce(signInURL) { $0.appendingPathComponent(String($1)) }
    }

    /// `application/x-www-form-urlencoded`, escaping everything except unreserved characters.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

enum ManagedAISignInError: LocalizedError, Equatable {
    /// Sign-in is set up but the person hasn't signed in.
    case notSignedIn
    /// The endpoint answered 401 to the signed-in key, so the key was removed.
    case signInExpired
    case stateMismatch
    case authorizationDenied
    case authorizationFailed(String)
    case timedOut
    case accountDeactivated
    case browserUnavailable
    case listenerFailed
    case networkError
    case serverError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Sign in with Equisolve to use AI cleanup.")
        case .signInExpired:
            return String(localized: "Your Equisolve sign-in is no longer valid. Sign in with Equisolve again to use AI cleanup.")
        case .stateMismatch:
            return String(localized: "The sign-in response didn't match this request. Try signing in again.")
        case .authorizationDenied:
            return String(localized: "Sign-in was canceled in the browser.")
        case .authorizationFailed(let error):
            return String(format: String(localized: "Sign-in failed: %@"), error)
        case .timedOut:
            return String(localized: "Sign-in timed out. Try again, and finish signing in within five minutes.")
        case .accountDeactivated:
            return String(localized: "Your Equisolve account is deactivated, so it can't get an AI key.")
        case .browserUnavailable:
            return String(localized: "VoiceInk couldn't open your web browser to sign in.")
        case .listenerFailed:
            return String(localized: "VoiceInk couldn't start listening for the sign-in response.")
        case .networkError:
            return String(localized: "VoiceInk couldn't reach the sign-in server. Check your connection.")
        case .serverError(let statusCode):
            return String(format: String(localized: "The sign-in server returned an error (HTTP %d)."), statusCode)
        case .invalidResponse:
            return String(localized: "The sign-in server sent a response VoiceInk couldn't read.")
        }
    }
}

/// Follows a redirect only when it stays on the sign-in server's scheme, host, and port.
final class ManagedSignInRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let signInURL: URL
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedAISignIn")

    init(signInURL: URL) {
        self.signInURL = signInURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, CloudPolicy.isManagedSignInRequestAllowed(url, signInURL: signInURL) else {
            logger.error(
                "Refused a redirect from the sign-in server to \(request.url?.host ?? "an unknown host", privacy: .public)"
            )
            return nil
        }
        return request
    }
}
