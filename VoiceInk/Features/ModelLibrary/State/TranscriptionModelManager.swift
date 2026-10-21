import Foundation
import SwiftUI
import os

@MainActor
class TranscriptionModelManager: ObservableObject {
    @Published var currentTranscriptionModel: (any TranscriptionModel)?
    @Published var allAvailableModels: [any TranscriptionModel] = TranscriptionModelRegistry.models

    private weak var whisperModelManager: WhisperModelManager?
    private weak var fluidAudioModelManager: FluidAudioModelManager?
    private let transcribeCppModelManager = TranscribeCppModelManager.shared

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionModelManager")

    init(whisperModelManager: WhisperModelManager, fluidAudioModelManager: FluidAudioModelManager) {
        self.whisperModelManager = whisperModelManager
        self.fluidAudioModelManager = fluidAudioModelManager

        // Wire up deletion callbacks so each manager notifies this manager.
        whisperModelManager.onModelDeleted = { [weak self] modelName in
            self?.handleModelDeleted(modelName)
        }
        fluidAudioModelManager.onModelDeleted = { [weak self] modelName in
            self?.handleModelDeleted(modelName)
        }
        transcribeCppModelManager.onModelDeleted = { [weak self] modelName in
            self?.handleModelDeleted(modelName)
        }

        // Wire up "models changed" callbacks so this manager rebuilds allAvailableModels.
        whisperModelManager.onModelsChanged = { [weak self] in
            self?.refreshAllAvailableModels()
        }
        fluidAudioModelManager.onModelsChanged = { [weak self] in
            self?.refreshAllAvailableModels()
        }
        transcribeCppModelManager.onModelsChanged = { [weak self] in
            self?.refreshAllAvailableModels()
        }

        cloudPolicyObserver = NotificationCenter.default.addObserver(
            forName: .cloudPolicyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCloudPolicy() }
        }
    }

    private var cloudPolicyObserver: NSObjectProtocol?

    /// Moves off a blocked cloud model when cloud services are turned off, and back to the saved model when
    /// they're turned on again. The saved choice in UserDefaults is never overwritten here.
    func applyCloudPolicy() {
        guard let savedSelection = AppPreferences.defaults.string(forKey: "CurrentTranscriptionModel"),
            let savedModel = TranscriptionModelRegistry.model(forSelectionKey: savedSelection, in: allAvailableModels),
            isAvailableOnCurrentOS(savedModel)
        else {
            if let current = currentTranscriptionModel, !CloudPolicy.isTranscriptionAllowed(current) {
                currentTranscriptionModel = cloudPolicyFallbackModel
            }
            return
        }

        currentTranscriptionModel = CloudPolicy.isTranscriptionAllowed(savedModel) ? savedModel : cloudPolicyFallbackModel
    }

    // MARK: - Computed: usable models

    var usableModels: [any TranscriptionModel] {
        allAvailableModels.filter { model in
            guard CloudPolicy.isTranscriptionAllowed(model) else { return false }

            switch model.provider {
            case .whisper:
                return whisperModelManager?.availableModels.contains { $0.name == model.name } ?? false
            case .fluidAudio:
                return fluidAudioModelManager?.isFluidAudioModelDownloaded(named: model.name) ?? false
            case .transcribeCpp:
                return transcribeCppModelManager.isModelDownloaded(named: model.name)
            case .nativeApple:
                if #available(macOS 26, *) { return true } else { return false }
            case .custom:
                return true
            default:
                if let cloudProvider = CloudProviderRegistry.provider(for: model.provider) {
                    return APIKeyManager.shared.hasAPIKey(forProvider: cloudProvider.providerKey)
                }
                return false
            }
        }
    }

    /// The local model to use in place of a blocked cloud model: the default model if it is allowed and ready,
    /// otherwise the first downloaded local model, otherwise nil.
    var cloudPolicyFallbackModel: (any TranscriptionModel)? {
        let usable = usableModels
        if let current = currentTranscriptionModel,
            usable.contains(where: { $0.selectionKey == current.selectionKey })
        {
            return current
        }
        return usable.first
    }

    func isAvailableOnCurrentOS(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .nativeApple:
            if #available(macOS 26, *) { return true } else { return false }
        default:
            return true
        }
    }

    // MARK: - Model loading from UserDefaults

    func loadCurrentTranscriptionModel() {
        if let savedModelName = AppPreferences.defaults.string(forKey: "CurrentTranscriptionModel"),
            let savedModel = TranscriptionModelRegistry.model(forSelectionKey: savedModelName, in: allAvailableModels)
        {
            guard isAvailableOnCurrentOS(savedModel) else {
                AppPreferences.defaults.removeObject(forKey: "CurrentTranscriptionModel")
                currentTranscriptionModel = nil
                return
            }

            guard CloudPolicy.isTranscriptionAllowed(savedModel) else {
                // Keep the saved cloud choice so it returns if the policy is lifted; use a local model meanwhile.
                currentTranscriptionModel = cloudPolicyFallbackModel
                return
            }

            currentTranscriptionModel = savedModel
            ensureSelectedLanguageIsSupported(by: savedModel)
        }
    }

    // MARK: - Set default model

    func setDefaultTranscriptionModel(_ model: any TranscriptionModel) {
        guard isAvailableOnCurrentOS(model) else {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "%@ requires macOS 26 or later"), model.displayName),
                type: .error
            )
            return
        }

        guard CloudPolicy.isTranscriptionAllowed(model) else {
            NotificationManager.shared.showNotification(
                title: CloudPolicyError.cloudTranscriptionDisabled.localizedDescription,
                type: .error
            )
            return
        }

        self.currentTranscriptionModel = model
        AppPreferences.defaults.set(model.selectionKey, forKey: "CurrentTranscriptionModel")
        ensureSelectedLanguageIsSupported(by: model)

        if model.provider != .whisper {
            whisperModelManager?.loadedWhisperModel = nil
            whisperModelManager?.isModelLoaded = true
        }

        NotificationCenter.default.post(name: .didChangeModel, object: nil, userInfo: ["modelName": model.name])
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func ensureSelectedLanguageIsSupported(by model: any TranscriptionModel) {
        let currentLanguage = AppPreferences.defaults.string(forKey: "SelectedLanguage")
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(currentLanguage, for: model)

        if currentLanguage != compatibleLanguage {
            AppPreferences.defaults.set(compatibleLanguage, forKey: "SelectedLanguage")
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    // MARK: - Refresh all available models

    func refreshAllAvailableModels() {
        let savedSelection = AppPreferences.defaults.string(forKey: "CurrentTranscriptionModel")
        // While cloud services are off, the current model may be a local stand-in, so restore from the saved choice.
        let currentSelection = CloudPolicy.isCloudAllowed
            ? currentTranscriptionModel?.selectionKey ?? savedSelection
            : savedSelection ?? currentTranscriptionModel?.selectionKey
        var models = TranscriptionModelRegistry.models

        for whisperModel in whisperModelManager?.availableModels ?? [] {
            if !models.contains(where: { $0.name == whisperModel.name }) {
                let importedModel = ImportedWhisperModel(fileBaseName: whisperModel.name)
                models.append(importedModel)
            }
        }

        allAvailableModels = models

        if let currentSelection,
            let updatedModel = TranscriptionModelRegistry.model(forSelectionKey: currentSelection, in: allAvailableModels)
        {
            if !CloudPolicy.isTranscriptionAllowed(updatedModel) {
                // Keep the saved cloud choice so it returns if the policy is lifted; use a local model meanwhile.
                currentTranscriptionModel = cloudPolicyFallbackModel
            } else if isAvailableOnCurrentOS(updatedModel) {
                setDefaultTranscriptionModel(updatedModel)
            } else {
                currentTranscriptionModel = nil
                AppPreferences.defaults.removeObject(forKey: "CurrentTranscriptionModel")
            }
        } else {
            currentTranscriptionModel = nil
        }

        NotificationCenter.default.post(name: .transcriptionModelsDidChange, object: nil)
    }

    func refreshOpenRouterCatalog() async {
        guard CloudPolicy.isCloudAllowed else { return }

        do {
            try await OpenRouterTranscriptionCatalog.refresh()
            refreshAllAvailableModels()
        } catch {
            logger.error("Failed to refresh OpenRouter transcription models: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Clear current model

    func clearCurrentTranscriptionModel() {
        currentTranscriptionModel = nil
        AppPreferences.defaults.removeObject(forKey: "CurrentTranscriptionModel")
    }

    // MARK: - Handle model deletion callback

    /// Called when one of the local model managers deletes a model.
    func handleModelDeleted(_ modelName: String) {
        if currentTranscriptionModel?.name == modelName {
            currentTranscriptionModel = nil
            AppPreferences.defaults.removeObject(forKey: "CurrentTranscriptionModel")
            whisperModelManager?.loadedWhisperModel = nil
            whisperModelManager?.isModelLoaded = false
            AppPreferences.defaults.removeObject(forKey: "CurrentModel")
        }
        refreshAllAvailableModels()
    }
}
