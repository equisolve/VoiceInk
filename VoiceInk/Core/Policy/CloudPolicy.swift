import Foundation

/// Organization policy for cloud transcription and AI services.
///
/// An administrator turns cloud services off by setting the Boolean `DisableCloudServices`
/// to true in a configuration profile for the app's preference domain. A value forced by a
/// profile wins over anything the user writes. When the key is false or absent, every
/// provider behaves as it does without this policy.
enum CloudPolicy {
    static let disableCloudServicesKey = "DisableCloudServices"

    /// Hosts an Ollama server or custom enhancement endpoint may use while cloud services are off.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// False when the organization has turned cloud services off.
    static var isCloudAllowed: Bool {
        isCloudAllowed(in: .standard)
    }

    static func isCloudAllowed(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: disableCloudServicesKey)
    }

    /// True when a configuration profile sets the key, so the UI can say the setting is managed.
    static var isManaged: Bool {
        UserDefaults.standard.objectIsForced(forKey: disableCloudServicesKey)
    }

    // MARK: - Transcription

    /// Providers that transcribe on this Mac. Every other provider, including any added later, is treated as cloud.
    static func isLocalTranscriptionProvider(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .whisper, .fluidAudio, .transcribeCpp, .nativeApple:
            return true
        default:
            return false
        }
    }

    static func isTranscriptionAllowed(_ provider: ModelProvider, cloudAllowed: Bool = isCloudAllowed) -> Bool {
        cloudAllowed || isLocalTranscriptionProvider(provider)
    }

    static func isTranscriptionAllowed(_ model: any TranscriptionModel, cloudAllowed: Bool = isCloudAllowed) -> Bool {
        isTranscriptionAllowed(model.provider, cloudAllowed: cloudAllowed)
    }

    static func allowedTranscriptionModels(
        _ models: [any TranscriptionModel],
        cloudAllowed: Bool = isCloudAllowed
    ) -> [any TranscriptionModel] {
        models.filter { isTranscriptionAllowed($0, cloudAllowed: cloudAllowed) }
    }

    /// Throws before any audio leaves the Mac when the provider is a blocked cloud service.
    static func requireTranscriptionAllowed(_ provider: ModelProvider, cloudAllowed: Bool = isCloudAllowed) throws {
        guard isTranscriptionAllowed(provider, cloudAllowed: cloudAllowed) else {
            throw CloudPolicyError.cloudTranscriptionDisabled
        }
    }

    // MARK: - AI enhancement

    /// The on-device model always passes. Ollama and a custom endpoint pass only when their URL is on a loopback
    /// host or inside the organization's managed AI endpoint. When `ollamaBaseURL` is nil, Ollama is checked against
    /// the saved server URL. The Local CLI provider is blocked because the command it runs can call cloud services.
    static func isEnhancementProviderAllowed(
        _ provider: AIProvider,
        customBaseURL: String? = nil,
        ollamaBaseURL: String? = nil,
        cloudAllowed: Bool = isCloudAllowed,
        managedEndpoint: ManagedAIEndpoint? = ManagedAIEndpoint.current
    ) -> Bool {
        if provider == .managed {
            guard let managedEndpoint else { return false }
            return cloudAllowed || isManagedEndpointAllowed(managedEndpoint)
        }

        if cloudAllowed { return true }

        switch provider {
        case .voiceInkRefine:
            return true
        case .ollama:
            return isAllowedEnhancementURL(ollamaBaseURL ?? AIProvider.ollama.baseURL, managedEndpoint: managedEndpoint)
        case .custom:
            return customBaseURL.map { isAllowedEnhancementURL($0, managedEndpoint: managedEndpoint) } ?? false
        default:
            return false
        }
    }

    /// While cloud services are off, a URL may receive text when it is on a loopback host or inside the managed endpoint.
    static func isAllowedEnhancementURL(_ urlString: String, managedEndpoint: ManagedAIEndpoint?) -> Bool {
        if isLoopbackURL(urlString) { return true }
        guard let managedEndpoint, isManagedEndpointAllowed(managedEndpoint) else { return false }
        return isWithinManagedEndpoint(urlString, managedEndpoint: managedEndpoint)
    }

    /// While cloud services are off, a managed endpoint off this Mac must use HTTPS so the token isn't sent in clear text.
    static func isManagedEndpointAllowed(_ endpoint: ManagedAIEndpoint) -> Bool {
        endpoint.baseURL.scheme?.lowercased() == "https" || isLoopbackURL(endpoint.baseURL.absoluteString)
    }

    /// True when the URL has the managed endpoint's scheme, host, and port, and its path starts with the endpoint's
    /// path at a segment boundary. `https://ai.example.com/v1` matches `https://ai.example.com:443/v1/chat`, but not
    /// `https://ai.example.com.evil.test/v1`, `http://ai.example.com/v1`, or `https://ai.example.com/v10`.
    static func isWithinManagedEndpoint(_ urlString: String, managedEndpoint: ManagedAIEndpoint) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URLComponents(string: trimmed),
            let managed = URLComponents(url: managedEndpoint.baseURL, resolvingAgainstBaseURL: false),
            let scheme = candidate.scheme?.lowercased(), scheme == managed.scheme?.lowercased(),
            let host = candidate.host?.lowercased(), !host.isEmpty, host == managed.host?.lowercased(),
            candidate.user == nil, candidate.password == nil,
            effectivePort(candidate) == effectivePort(managed)
        else {
            return false
        }

        let managedSegments = pathSegments(managed.percentEncodedPath)
        let candidateSegments = pathSegments(candidate.percentEncodedPath)
        guard !candidateSegments.contains(".."), !candidateSegments.contains(".") else { return false }
        return candidateSegments.starts(with: managedSegments)
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func pathSegments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
    }

    /// Throws before any text leaves the Mac when the provider, Ollama server, or custom endpoint is blocked.
    static func requireEnhancementProviderAllowed(
        _ provider: AIProvider,
        customBaseURL: String? = nil,
        ollamaBaseURL: String? = nil,
        cloudAllowed: Bool = isCloudAllowed,
        managedEndpoint: ManagedAIEndpoint? = ManagedAIEndpoint.current
    ) throws {
        guard
            isEnhancementProviderAllowed(
                provider, customBaseURL: customBaseURL, ollamaBaseURL: ollamaBaseURL, cloudAllowed: cloudAllowed,
                managedEndpoint: managedEndpoint)
        else {
            throw CloudPolicyError.cloudEnhancementDisabled(providerName: provider.rawValue)
        }
    }

    static func isLoopbackURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return false }
        let unbracketedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return loopbackHosts.contains(unbracketedHost)
    }
}

extension Notification.Name {
    /// Posted on the main thread when `DisableCloudServices` or the managed AI endpoint changes, including when a
    /// configuration profile is installed or removed while the app runs.
    static let cloudPolicyDidChange = Notification.Name("cloudPolicyDidChange")
}

/// Watches `DisableCloudServices` and the managed AI endpoint keys so model selection and open screens follow a
/// change without a relaunch.
@MainActor
final class CloudPolicyMonitor: NSObject, ObservableObject {
    static let shared = CloudPolicyMonitor()

    nonisolated private static let observedKeys = [CloudPolicy.disableCloudServicesKey] + ManagedAIEndpoint.allKeys

    @Published private(set) var isCloudAllowed = CloudPolicy.isCloudAllowed
    @Published private(set) var managedEndpoint = ManagedAIEndpoint.current
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        isCloudAllowed = CloudPolicy.isCloudAllowed
        managedEndpoint = ManagedAIEndpoint.current
        for key in Self.observedKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath, Self.observedKeys.contains(keyPath) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    /// Re-reads the keys and notifies observers when the effective policy or managed endpoint changed.
    /// The token isn't tracked here; requests read it each time.
    func refresh() {
        let allowed = CloudPolicy.isCloudAllowed
        let endpoint = ManagedAIEndpoint.current
        guard allowed != isCloudAllowed || endpoint != managedEndpoint else { return }
        isCloudAllowed = allowed
        managedEndpoint = endpoint
        NotificationCenter.default.post(name: .cloudPolicyDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }
}

enum CloudPolicyError: Error, LocalizedError, Equatable {
    case cloudTranscriptionDisabled
    case cloudEnhancementDisabled(providerName: String)
    case cloudEndpointDisabled

    var errorDescription: String? {
        switch self {
        case .cloudTranscriptionDisabled:
            return String(
                localized: "Your organization has turned off cloud transcription. Choose a local transcription model."
            )
        case .cloudEnhancementDisabled(let providerName):
            return String(
                format: String(
                    localized: "Your organization has turned off %@. The transcript was kept without AI enhancement."
                ),
                providerName
            )
        case .cloudEndpointDisabled:
            if let endpoint = ManagedAIEndpoint.current {
                return String(
                    format: String(
                        localized:
                            "Your organization allows only endpoints on this Mac (localhost, 127.0.0.1, or ::1) and %@."
                    ),
                    endpoint.providerName
                )
            }
            return String(
                localized: "Your organization allows only endpoints on this Mac (localhost, 127.0.0.1, or ::1)."
            )
        }
    }
}
