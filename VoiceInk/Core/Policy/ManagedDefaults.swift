import Foundation

/// Starting settings an organization pushes in a configuration profile. Unlike `DisableCloudServices`, these are
/// defaults: VoiceInk copies them into its own settings once per `ManagedDefaultsVersion`, and the person using the
/// Mac can change them afterward. The profile keys stay separate from the settings they seed, because a profile
/// forces every key it sets.
struct ManagedDefaults: Equatable {
    static let transcriptionModelKey = "DefaultTranscriptionModel"
    static let enhancementProviderKey = "DefaultEnhancementProvider"
    static let enhancementModelKey = "DefaultEnhancementModel"
    static let enhancementEnabledKey = "DefaultEnhancementEnabled"
    static let autoDownloadModelsKey = "AutoDownloadModels"
    static let versionKey = "ManagedDefaultsVersion"

    static let profileKeys = [
        transcriptionModelKey, enhancementProviderKey, enhancementModelKey,
        enhancementEnabledKey, autoDownloadModelsKey, versionKey,
    ]

    /// VoiceInk's own record of the last version it applied. Never set by a profile.
    static let appliedVersionKey = "ManagedDefaultsAppliedVersion"
    /// The default transcription model waiting for its download to finish, and the model that was selected when
    /// it was queued. VoiceInk switches only if the selection hasn't changed since.
    static let pendingTranscriptionModelKey = "ManagedDefaultsPendingTranscriptionModel"
    static let pendingReplacedModelKey = "ManagedDefaultsPendingReplacedModel"

    var transcriptionModel: String?
    var enhancementProvider: String?
    var enhancementModel: String?
    var enhancementEnabled: Bool?
    var autoDownloadModels: [String]
    var version: Int?

    init(
        transcriptionModel: String? = nil,
        enhancementProvider: String? = nil,
        enhancementModel: String? = nil,
        enhancementEnabled: Bool? = nil,
        autoDownloadModels: [String] = [],
        version: Int? = nil
    ) {
        self.transcriptionModel = transcriptionModel
        self.enhancementProvider = enhancementProvider
        self.enhancementModel = enhancementModel
        self.enhancementEnabled = enhancementEnabled
        self.autoDownloadModels = autoDownloadModels
        self.version = version
    }

    init(defaults: UserDefaults) {
        func string(_ key: String) -> String? {
            let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }

        self.init(
            transcriptionModel: string(Self.transcriptionModelKey),
            enhancementProvider: string(Self.enhancementProviderKey),
            enhancementModel: string(Self.enhancementModelKey),
            enhancementEnabled: defaults.object(forKey: Self.enhancementEnabledKey) == nil
                ? nil : defaults.bool(forKey: Self.enhancementEnabledKey),
            autoDownloadModels: (defaults.array(forKey: Self.autoDownloadModelsKey) as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            version: defaults.object(forKey: Self.versionKey) == nil
                ? nil : defaults.integer(forKey: Self.versionKey)
        )
    }

    static var current: ManagedDefaults { ManagedDefaults(defaults: .standard) }

    /// True when the profile sets up transcription or enhancement, so onboarding can skip choosing a model and
    /// entering an API key.
    var isPresent: Bool {
        transcriptionModel != nil || enhancementProvider != nil || enhancementEnabled != nil
            || !autoDownloadModels.isEmpty
    }
}

/// A model VoiceInk can download for the organization.
enum ManagedModelDownload: Equatable {
    case transcription(selectionKey: String)
    case voiceInkRefine

    /// The download a transcription model needs, or nil for one that runs without a download (Apple Speech or a
    /// cloud model).
    init?(transcriptionModel model: any TranscriptionModel) {
        switch model.provider {
        case .whisper, .fluidAudio, .transcribeCpp:
            self = .transcription(selectionKey: model.selectionKey)
        default:
            return nil
        }
    }
}

/// What the managed defaults mean on this Mac: the models and provider that resolve and are allowed, the downloads
/// to start, and a log line for each value that was ignored.
struct ManagedDefaultsResolution {
    var transcriptionModel: (any TranscriptionModel)?
    var enhancementProvider: AIProvider?
    var enhancementModel: String?
    var enhancementEnabled: Bool?
    var downloads: [ManagedModelDownload] = []
    var ignored: [String] = []

    /// - Parameter voiceInkRefineUnavailableReason: Why VoiceInk Refine can't run on this Mac, or nil when it can.
    ///   Comes from `VoiceInkRefineService.unavailableDescription` (Apple silicon with at least 16 GB of memory).
    /// - Parameter managedEndpoint: The organization AI endpoint, which `DefaultEnhancementProvider` can name.
    init(
        _ managed: ManagedDefaults,
        transcriptionModels: [any TranscriptionModel],
        isCloudAllowed: Bool,
        voiceInkRefineUnavailableReason: String?,
        managedEndpoint: ManagedAIEndpoint? = ManagedAIEndpoint.current
    ) {
        if let id = managed.transcriptionModel {
            if let model = TranscriptionModelRegistry.model(forSelectionKey: id, in: transcriptionModels) {
                if CloudPolicy.isTranscriptionAllowed(model, cloudAllowed: isCloudAllowed) {
                    transcriptionModel = model
                } else {
                    ignored.append("\(ManagedDefaults.transcriptionModelKey) \(id) is a cloud model and cloud services are off")
                }
            } else {
                ignored.append("\(ManagedDefaults.transcriptionModelKey) \(id) is not a known model")
            }
        }

        if let name = managed.enhancementProvider {
            if let provider = Self.enhancementProvider(named: name, managedEndpoint: managedEndpoint) {
                if provider == .managed {
                    resolveManagedProvider(
                        named: name, endpoint: managedEndpoint, isCloudAllowed: isCloudAllowed,
                        voiceInkRefineUnavailableReason: voiceInkRefineUnavailableReason)
                } else if !CloudPolicy.isEnhancementProviderAllowed(
                    provider, cloudAllowed: isCloudAllowed, managedEndpoint: managedEndpoint)
                {
                    ignored.append("\(ManagedDefaults.enhancementProviderKey) \(name) is blocked while cloud services are off")
                } else if provider == .voiceInkRefine, let reason = voiceInkRefineUnavailableReason {
                    ignored.append("\(ManagedDefaults.enhancementProviderKey) \(name) can't run on this Mac: \(reason)")
                } else {
                    enhancementProvider = provider
                    enhancementModel = provider == .voiceInkRefine ? provider.defaultModel : managed.enhancementModel
                }
            } else {
                ignored.append("\(ManagedDefaults.enhancementProviderKey) \(name) is not an enhancement provider")
            }
        }

        // Turning enhancement on only makes sense with the provider the organization chose. Turning it off is
        // always safe.
        if managed.enhancementEnabled == true, managed.enhancementProvider != nil, enhancementProvider == nil {
            ignored.append(
                "\(ManagedDefaults.enhancementEnabledKey) is ignored because \(ManagedDefaults.enhancementProviderKey) wasn't applied"
            )
        } else {
            enhancementEnabled = managed.enhancementEnabled
        }

        for id in managed.autoDownloadModels {
            if id.caseInsensitiveCompare(VoiceInkRefineService.modelName) == .orderedSame
                || id.caseInsensitiveCompare(VoiceInkRefineService.providerName) == .orderedSame
            {
                if let reason = voiceInkRefineUnavailableReason {
                    ignored.append("\(ManagedDefaults.autoDownloadModelsKey) \(id) can't run on this Mac: \(reason)")
                } else {
                    append(.voiceInkRefine)
                }
            } else if let model = TranscriptionModelRegistry.model(forSelectionKey: id, in: transcriptionModels) {
                if let download = ManagedModelDownload(transcriptionModel: model) {
                    append(download)
                } else {
                    ignored.append("\(ManagedDefaults.autoDownloadModelsKey) \(id) is not a downloadable model")
                }
            } else {
                ignored.append("\(ManagedDefaults.autoDownloadModelsKey) \(id) is not a known model")
            }
        }
    }

    private mutating func append(_ download: ManagedModelDownload) {
        if !downloads.contains(download) { downloads.append(download) }
    }

    /// The organization provider matches `Managed` or its `ManagedAIProviderName`.
    static func enhancementProvider(
        named name: String,
        managedEndpoint: ManagedAIEndpoint? = ManagedAIEndpoint.current
    ) -> AIProvider? {
        if let managedEndpoint, managedEndpoint.providerName.caseInsensitiveCompare(name) == .orderedSame {
            return .managed
        }
        return AIProvider.allCases.first {
            $0.supportsEnhancement && $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Selects the organization provider when its endpoint is set up and allowed. Otherwise falls back to
    /// VoiceInk Refine when it can run on this Mac, so enhancement still has a local default.
    private mutating func resolveManagedProvider(
        named name: String,
        endpoint: ManagedAIEndpoint?,
        isCloudAllowed: Bool,
        voiceInkRefineUnavailableReason: String?
    ) {
        if let endpoint,
            CloudPolicy.isEnhancementProviderAllowed(.managed, cloudAllowed: isCloudAllowed, managedEndpoint: endpoint)
        {
            enhancementProvider = .managed
            enhancementModel = endpoint.model
            return
        }

        let reason =
            endpoint == nil
            ? "\(ManagedAIEndpoint.endpointURLKey) and \(ManagedAIEndpoint.modelKey) aren't both set"
            : "its endpoint must use https or a loopback host while cloud services are off"
        if voiceInkRefineUnavailableReason == nil {
            ignored.append("\(ManagedDefaults.enhancementProviderKey) \(name) is unavailable because \(reason); using VoiceInk Refine")
            enhancementProvider = .voiceInkRefine
            enhancementModel = AIProvider.voiceInkRefine.defaultModel
        } else {
            ignored.append("\(ManagedDefaults.enhancementProviderKey) \(name) is unavailable because \(reason)")
        }
    }
}
