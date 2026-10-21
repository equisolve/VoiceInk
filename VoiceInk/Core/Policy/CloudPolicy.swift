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

    /// The on-device model always passes. Ollama and a custom endpoint pass only when their host is a loopback address.
    /// When `ollamaBaseURL` is nil, Ollama is checked against the saved server URL.
    /// The Local CLI provider is blocked because the command it runs can call cloud services.
    static func isEnhancementProviderAllowed(
        _ provider: AIProvider,
        customBaseURL: String? = nil,
        ollamaBaseURL: String? = nil,
        cloudAllowed: Bool = isCloudAllowed
    ) -> Bool {
        if cloudAllowed { return true }

        switch provider {
        case .voiceInkRefine:
            return true
        case .ollama:
            return isLoopbackURL(ollamaBaseURL ?? AIProvider.ollama.baseURL)
        case .custom:
            return customBaseURL.map(isLoopbackURL) ?? false
        default:
            return false
        }
    }

    /// Throws before any text leaves the Mac when the provider, Ollama server, or custom endpoint is blocked.
    static func requireEnhancementProviderAllowed(
        _ provider: AIProvider,
        customBaseURL: String? = nil,
        ollamaBaseURL: String? = nil,
        cloudAllowed: Bool = isCloudAllowed
    ) throws {
        guard
            isEnhancementProviderAllowed(
                provider, customBaseURL: customBaseURL, ollamaBaseURL: ollamaBaseURL, cloudAllowed: cloudAllowed)
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
    /// Posted on the main thread when `DisableCloudServices` changes, including when a configuration profile is
    /// installed or removed while the app runs.
    static let cloudPolicyDidChange = Notification.Name("cloudPolicyDidChange")
}

/// Watches `DisableCloudServices` so model selection and open screens follow a policy change without a relaunch.
@MainActor
final class CloudPolicyMonitor: NSObject, ObservableObject {
    static let shared = CloudPolicyMonitor()

    @Published private(set) var isCloudAllowed = CloudPolicy.isCloudAllowed
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        isCloudAllowed = CloudPolicy.isCloudAllowed
        UserDefaults.standard.addObserver(self, forKeyPath: CloudPolicy.disableCloudServicesKey, options: [.new], context: nil)
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == CloudPolicy.disableCloudServicesKey else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    /// Re-reads the key and notifies observers when the effective value changed.
    func refresh() {
        let allowed = CloudPolicy.isCloudAllowed
        guard allowed != isCloudAllowed else { return }
        isCloudAllowed = allowed
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
            return String(
                localized: "Your organization allows only endpoints on this Mac (localhost, 127.0.0.1, or ::1)."
            )
        }
    }
}
