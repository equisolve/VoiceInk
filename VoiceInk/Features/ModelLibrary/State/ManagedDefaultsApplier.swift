import Foundation
import OSLog

/// The app state that managed defaults read and write. `LiveManagedDefaultsTarget` connects it to the running app;
/// tests use a stand-in.
@MainActor
protocol ManagedDefaultsTarget: AnyObject {
    var transcriptionModels: [any TranscriptionModel] { get }
    var currentTranscriptionSelectionKey: String? { get }
    /// False until onboarding has finished and set up the starter modes that the defaults are written into.
    var canApplySettings: Bool { get }
    /// Why VoiceInk Refine can't run on this Mac, or nil when it can.
    var voiceInkRefineUnavailableReason: String? { get }
    /// True when the person has set a recording shortcut or removed it on purpose.
    var hasChosenRecordingShortcut: Bool { get }

    func isDownloaded(_ download: ManagedModelDownload) -> Bool
    func isDownloading(_ download: ManagedModelDownload) -> Bool
    func startDownload(_ download: ManagedModelDownload)
    func selectTranscriptionModel(_ model: any TranscriptionModel)
    func applyEnhancement(provider: AIProvider?, model: String?, enabled: Bool?)
    func setRecordingShortcut(_ shortcut: Shortcut)
    /// Selects the locked provider as the global AI enhancement provider. Modes keep their saved provider.
    func applyEnhancementLock(_ lock: EnhancementProviderLock)
}

/// Applies the organization's managed defaults (see `ManagedDefaults`).
///
/// Downloads start on every launch and whenever the profile changes, so a failed download is retried. Settings are
/// written only when `ManagedDefaultsVersion` is greater than the version applied last, and that version is then
/// recorded, so a change the person makes afterward survives relaunches until the organization bumps the version.
@MainActor
final class ManagedDefaultsApplier: NSObject {
    private let defaults: UserDefaults
    private let target: ManagedDefaultsTarget
    private let isCloudAllowed: () -> Bool
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedDefaults")
    private var isObserving = false
    private var observers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = AppPreferences.defaults,
        target: ManagedDefaultsTarget,
        isCloudAllowed: @escaping () -> Bool = { CloudPolicy.isCloudAllowed }
    ) {
        self.defaults = defaults
        self.target = target
        self.isCloudAllowed = isCloudAllowed
    }

    var appliedVersion: Int { defaults.integer(forKey: ManagedDefaults.appliedVersionKey) }

    /// Applies the defaults now and again whenever the profile, onboarding, or the downloaded models change.
    func start() {
        guard !isObserving else { return }
        isObserving = true
        for key in ManagedDefaults.profileKeys + [OnboardingSettings.completedV2Key] {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .transcriptionModelsDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.switchToPendingTranscriptionModel() }
            })
        apply()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        for key in ManagedDefaults.profileKeys + [OnboardingSettings.completedV2Key] {
            defaults.removeObserver(self, forKeyPath: key)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.apply() }
        }
    }

    private func resolve(_ managed: ManagedDefaults) -> ManagedDefaultsResolution {
        ManagedDefaultsResolution(
            managed,
            transcriptionModels: target.transcriptionModels,
            isCloudAllowed: isCloudAllowed(),
            voiceInkRefineUnavailableReason: target.voiceInkRefineUnavailableReason,
            managedEndpoint: ManagedAIEndpoint.current(in: defaults)
        )
    }

    func apply() {
        let managed = ManagedDefaults(defaults: defaults)
        let resolution = resolve(managed)

        for reason in resolution.ignored {
            logger.warning("Ignored managed default: \(reason, privacy: .public)")
        }

        startDownloads(resolution.downloads)
        applySettingsIfNeeded(managed, resolution: resolution)
        applyEnhancementLock()
        switchToPendingTranscriptionModel()
    }

    /// The provider lock applies on every launch and profile change, not once per version, because the person can't
    /// change it.
    private func applyEnhancementLock() {
        let (lock, ignored) = EnhancementProviderLock.resolve(
            defaults: defaults,
            isCloudAllowed: isCloudAllowed(),
            voiceInkRefineUnavailableReason: target.voiceInkRefineUnavailableReason,
            managedEndpoint: ManagedAIEndpoint.current(in: defaults)
        )
        for reason in ignored {
            logger.warning("Provider lock: \(reason, privacy: .public)")
        }
        guard let lock, target.canApplySettings else { return }
        target.applyEnhancementLock(lock)
        logger.notice("Locked AI enhancement provider to \(lock.provider.rawValue, privacy: .public)")
    }

    private func startDownloads(_ downloads: [ManagedModelDownload]) {
        for download in downloads where !target.isDownloaded(download) && !target.isDownloading(download) {
            logger.notice("Downloading managed model \(String(describing: download), privacy: .public)")
            target.startDownload(download)
        }
    }

    private func applySettingsIfNeeded(_ managed: ManagedDefaults, resolution: ManagedDefaultsResolution) {
        guard let version = managed.version, version > appliedVersion else { return }
        guard target.canApplySettings else { return }

        clearPendingTranscriptionModel()
        if let model = resolution.transcriptionModel {
            if let download = ManagedModelDownload(transcriptionModel: model), !target.isDownloaded(download) {
                // Keep the current model until the download finishes.
                defaults.set(model.selectionKey, forKey: ManagedDefaults.pendingTranscriptionModelKey)
                defaults.set(target.currentTranscriptionSelectionKey, forKey: ManagedDefaults.pendingReplacedModelKey)
            } else {
                target.selectTranscriptionModel(model)
            }
        }

        if resolution.enhancementProvider != nil || resolution.enhancementEnabled != nil {
            target.applyEnhancement(
                provider: resolution.enhancementProvider,
                model: resolution.enhancementModel,
                enabled: resolution.enhancementEnabled
            )
        }

        // A shortcut the person chose always wins, even after the organization bumps the version.
        if let shortcut = resolution.shortcut, !target.hasChosenRecordingShortcut {
            target.setRecordingShortcut(shortcut)
        }

        defaults.set(version, forKey: ManagedDefaults.appliedVersionKey)
        logger.notice("Applied managed defaults version \(version, privacy: .public)")
    }

    /// Switches to the default transcription model once it's downloaded, unless the person picked another model
    /// in the meantime or the organization changed the default.
    func switchToPendingTranscriptionModel() {
        guard let pending = defaults.string(forKey: ManagedDefaults.pendingTranscriptionModelKey) else { return }

        let resolution = resolve(ManagedDefaults(defaults: defaults))
        guard let model = resolution.transcriptionModel, model.selectionKey == pending,
            target.currentTranscriptionSelectionKey == defaults.string(forKey: ManagedDefaults.pendingReplacedModelKey)
        else {
            clearPendingTranscriptionModel()
            return
        }

        guard target.isDownloaded(.transcription(selectionKey: pending)) else { return }

        clearPendingTranscriptionModel()
        target.selectTranscriptionModel(model)
        logger.notice("Switched to managed transcription model \(pending, privacy: .public)")
    }

    private func clearPendingTranscriptionModel() {
        defaults.removeObject(forKey: ManagedDefaults.pendingTranscriptionModelKey)
        defaults.removeObject(forKey: ManagedDefaults.pendingReplacedModelKey)
    }
}

extension Notification.Name {
    /// Posted when the list of downloaded or imported transcription models changes.
    static let transcriptionModelsDidChange = Notification.Name("transcriptionModelsDidChange")
}

/// Connects managed defaults to the running app's model managers, AI service, and default mode.
@MainActor
final class LiveManagedDefaultsTarget: ManagedDefaultsTarget {
    private let transcriptionModelManager: TranscriptionModelManager
    private let whisperModelManager: WhisperModelManager
    private let fluidAudioModelManager: FluidAudioModelManager
    private let aiService: AIService
    private let transcribeCppModelManager = TranscribeCppModelManager.shared
    private let voiceInkRefineService = VoiceInkRefineService.shared

    init(
        transcriptionModelManager: TranscriptionModelManager,
        whisperModelManager: WhisperModelManager,
        fluidAudioModelManager: FluidAudioModelManager,
        aiService: AIService
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.whisperModelManager = whisperModelManager
        self.fluidAudioModelManager = fluidAudioModelManager
        self.aiService = aiService
    }

    var transcriptionModels: [any TranscriptionModel] { transcriptionModelManager.allAvailableModels }

    var currentTranscriptionSelectionKey: String? {
        ModeManager.shared.getDefaultConfiguration()?.selectedTranscriptionModelName
            ?? AppPreferences.defaults.string(forKey: "CurrentTranscriptionModel")
    }

    var canApplySettings: Bool {
        UserDefaults.standard.bool(forKey: OnboardingSettings.completedV2Key)
    }

    var voiceInkRefineUnavailableReason: String? { voiceInkRefineService.unavailableDescription }

    var hasChosenRecordingShortcut: Bool {
        ShortcutStore.rawShortcut(for: .primaryRecording) != nil || ShortcutStore.isShortcutCleared(for: .primaryRecording)
    }

    func setRecordingShortcut(_ shortcut: Shortcut) {
        ShortcutStore.seedShortcut(shortcut, for: .primaryRecording)
    }

    func isDownloaded(_ download: ManagedModelDownload) -> Bool {
        switch download {
        case .voiceInkRefine:
            return voiceInkRefineService.isDownloaded
        case .transcription(let key):
            guard let model = model(forKey: key) else { return false }
            switch model {
            case let model as WhisperModel:
                return whisperModelManager.availableModels.contains { $0.name == model.name }
            case let model as FluidAudioModel:
                return fluidAudioModelManager.isFluidAudioModelDownloaded(model)
            case let model as TranscribeCppModel:
                return transcribeCppModelManager.isModelDownloaded(model)
            case is ImportedWhisperModel:
                // Listed only while its file is on disk.
                return true
            default:
                return false
            }
        }
    }

    func isDownloading(_ download: ManagedModelDownload) -> Bool {
        switch download {
        case .voiceInkRefine:
            return voiceInkRefineService.isDownloading
        case .transcription(let key):
            switch model(forKey: key) {
            case let model as WhisperModel:
                return whisperModelManager.downloadProgress[model.name + "_main"] != nil
            case let model as FluidAudioModel:
                return fluidAudioModelManager.isFluidAudioModelDownloading(model)
            case let model as TranscribeCppModel:
                return transcribeCppModelManager.isModelDownloading(model)
            default:
                return false
            }
        }
    }

    func startDownload(_ download: ManagedModelDownload) {
        switch download {
        case .voiceInkRefine:
            voiceInkRefineService.startDownload()
        case .transcription(let key):
            switch model(forKey: key) {
            case let model as WhisperModel:
                whisperModelManager.startDownload(model)
            case let model as FluidAudioModel:
                fluidAudioModelManager.startDownload(model)
            case let model as TranscribeCppModel:
                transcribeCppModelManager.startDownload(model)
            default:
                break
            }
        }
    }

    func selectTranscriptionModel(_ model: any TranscriptionModel) {
        transcriptionModelManager.setDefaultTranscriptionModel(model)
        updateDefaultMode { mode in
            mode.selectedTranscriptionModelName = model.selectionKey
            mode.selectedLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(mode.selectedLanguage, for: model)
        }
    }

    func applyEnhancement(provider: AIProvider?, model: String?, enabled: Bool?) {
        if let provider {
            aiService.selectedProvider = provider
            aiService.selectModel(model ?? provider.defaultModel, for: provider)
        }

        updateDefaultMode { mode in
            if let provider {
                mode.selectedAIProvider = provider.rawValue
                mode.selectedAIModel = model ?? provider.defaultModel
            }
            if let enabled {
                mode.isAIEnhancementEnabled = enabled
                if enabled, mode.selectedPrompt == nil {
                    mode.selectedPrompt = PromptTemplates.defaultPromptId.uuidString
                }
            }
        }
    }

    func applyEnhancementLock(_ lock: EnhancementProviderLock) {
        if aiService.selectedProvider != lock.provider {
            aiService.selectedProvider = lock.provider
        }
        if let model = lock.model, aiService.selectedModel(for: lock.provider) != model {
            aiService.selectModel(model, for: lock.provider)
        }
    }

    private func updateDefaultMode(_ change: (inout ModeConfig) -> Void) {
        guard var mode = ModeManager.shared.getDefaultConfiguration() else { return }
        change(&mode)
        ModeManager.shared.updateConfiguration(mode)
    }

    private func model(forKey key: String) -> (any TranscriptionModel)? {
        TranscriptionModelRegistry.model(forSelectionKey: key, in: transcriptionModels)
    }
}
