import Foundation

/// An OpenAI-compatible AI endpoint that an administrator configures through managed preferences.
///
/// When `ManagedAIEndpointURL` and `ManagedAIModel` are set, VoiceInk offers a read-only enhancement provider built from
/// them. The token is read from preferences for each request and is never copied anywhere else.
struct ManagedAIEndpoint: Equatable {
    static let endpointURLKey = "ManagedAIEndpointURL"
    static let modelKey = "ManagedAIModel"
    static let tokenKey = "ManagedAIToken"
    static let providerNameKey = "ManagedAIProviderName"
    static let allKeys = [endpointURLKey, modelKey, tokenKey, providerNameKey]

    static let defaultProviderName = String(localized: "Organization AI")

    let baseURL: URL
    let model: String
    let providerName: String

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
            providerName: trimmedString(defaults, providerNameKey) ?? defaultProviderName
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

    /// Where chat requests go: the base URL plus `chat/completions`, or the URL as given when it already ends there.
    var chatCompletionsURL: URL {
        let path = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if path.hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }

    /// The bearer token, read at request time. Empty when no token is configured.
    static func token(in defaults: UserDefaults = AppPreferences.defaults) -> String {
        trimmedString(defaults, tokenKey) ?? ""
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
