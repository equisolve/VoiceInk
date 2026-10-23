import Foundation

/// An OpenAI-compatible AI endpoint that an administrator configures through managed preferences.
///
/// When `ManagedAIEndpointURL` and `ManagedAIModel` are set, VoiceInk offers a read-only enhancement provider built from
/// them. The token is read from preferences for each request and is never copied anywhere else. When
/// `ManagedAISignInURL` is also set, each person can sign in with Equisolve to get their own key instead (see
/// `ManagedAISignInClient`).
struct ManagedAIEndpoint: Equatable {
    static let endpointURLKey = "ManagedAIEndpointURL"
    static let modelKey = "ManagedAIModel"
    static let tokenKey = "ManagedAIToken"
    static let providerNameKey = "ManagedAIProviderName"
    static let signInURLKey = "ManagedAISignInURL"
    static let allKeys = [endpointURLKey, modelKey, tokenKey, providerNameKey, signInURLKey]

    static let defaultProviderName = String(localized: "Organization AI")

    let baseURL: URL
    let model: String
    let providerName: String
    /// The server people sign in to for their own key, or nil when sign-in isn't set up or its URL isn't valid.
    var signInURL: URL? = nil

    /// The configured endpoint, or nil when the URL or model is missing or the URL isn't a valid base URL.
    static var current: ManagedAIEndpoint? {
        current(in: AppPreferences.defaults)
    }

    static func current(in defaults: UserDefaults) -> ManagedAIEndpoint? {
        guard let urlString = trimmedString(defaults, endpointURLKey),
            let url = URL(string: urlString),
            isValidBaseURL(url),
            let model = trimmedString(defaults, modelKey)
        else {
            return nil
        }

        return ManagedAIEndpoint(
            baseURL: url,
            model: model,
            providerName: trimmedString(defaults, providerNameKey) ?? defaultProviderName,
            signInURL: signInURL(in: defaults)
        )
    }

    /// True for an HTTP or HTTPS URL with a host and no user info, query, or fragment. Credentials belong in
    /// `ManagedAIToken`, and a query or fragment would be lost when the request path is appended.
    static func isValidBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            components.host?.isEmpty == false
        else {
            return false
        }
        return components.user == nil && components.password == nil && components.query == nil
            && components.fragment == nil
    }

    /// The rules of `isValidBaseURL`, and the URL must use HTTPS, because signing in returns a key.
    static func isValidSignInURL(_ url: URL) -> Bool {
        isValidBaseURL(url) && url.scheme?.lowercased() == "https"
    }

    /// The `ManagedAISignInURL` value, or nil when it's missing or not a valid sign-in URL.
    static func signInURL(in defaults: UserDefaults) -> URL? {
        guard let urlString = trimmedString(defaults, signInURLKey),
            let url = URL(string: urlString),
            isValidSignInURL(url)
        else {
            return nil
        }
        return url
    }

    /// Where chat requests go: the base URL plus `chat/completions`, or the URL as given when it already ends there.
    var chatCompletionsURL: URL {
        let path = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if path.hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }

    /// The bearer token from preferences, read at request time. Empty when no token is configured.
    static func token(in defaults: UserDefaults = AppPreferences.defaults) -> String {
        trimmedString(defaults, tokenKey) ?? ""
    }

    /// The credential for a request to this endpoint, read at request time. See `ManagedAICredential.resolve`.
    func credential(
        in defaults: UserDefaults = AppPreferences.defaults,
        keyStore: ManagedAIKeyStore = .shared
    ) -> ManagedAICredential {
        ManagedAICredential.resolve(
            profileToken: Self.token(in: defaults),
            signInConfigured: signInURL != nil,
            signedInKey: signInURL == nil ? nil : keyStore.load()?.apiKey
        )
    }

    /// True when the endpoint is set up for sign-in, the profile sets no `ManagedAIToken`, and nobody has signed in,
    /// so AI enhancement through the endpoint can't run until the person signs in. Matches the `.signInRequired` case
    /// of `ManagedAICredential.resolve`.
    static func requiresSignIn(endpoint: ManagedAIEndpoint?, profileToken: String, isSignedIn: Bool) -> Bool {
        guard let endpoint, endpoint.signInURL != nil else { return false }
        return profileToken.isEmpty && !isSignedIn
    }

    /// True when a configuration profile sets the endpoint, so the UI can say it's managed.
    static var isManaged: Bool {
        AppPreferences.defaults.objectIsForced(forKey: endpointURLKey)
    }

    private static func trimmedString(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// The credential a request to the managed endpoint sends.
enum ManagedAICredential: Equatable {
    /// `ManagedAIToken` from preferences.
    case profileToken(String)
    /// The key saved when the person signed in with Equisolve.
    case signedInKey(String)
    /// No token is set and sign-in isn't set up, so the request has no `Authorization` header.
    case none
    /// Sign-in is set up but the person hasn't signed in, so no request is sent.
    case signInRequired

    /// `ManagedAIToken` wins when it's set. Otherwise the signed-in key is used, but only while sign-in is set up, so
    /// removing `ManagedAISignInURL` from the profile stops a saved key from being sent.
    static func resolve(profileToken: String, signInConfigured: Bool, signedInKey: String?) -> ManagedAICredential {
        if !profileToken.isEmpty {
            return .profileToken(profileToken)
        }
        guard signInConfigured else { return .none }
        if let signedInKey, !signedInKey.isEmpty {
            return .signedInKey(signedInKey)
        }
        return .signInRequired
    }

    /// The bearer token to send. Empty for `.none` and `.signInRequired`.
    var token: String {
        switch self {
        case .profileToken(let token), .signedInKey(let token):
            return token
        case .none, .signInRequired:
            return ""
        }
    }
}
