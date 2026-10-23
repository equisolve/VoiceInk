import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig
    let model: any TranscriptionModel
    let language: String
    let isRealtimeEnabled: Bool

    var metadata: (name: String?, emoji: String?) {
        guard mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: language,
            prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil
        )
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let autoSendKey: FinishAndSendKey
    let customCommand: ModeCustomCommand?
}

enum ModeTranscriptionModelResolution {
    case noMode
    case noSelection(mode: ModeConfig)
    case modelNotFound(mode: ModeConfig)
    case unavailable(mode: ModeConfig, model: any TranscriptionModel)
    case available(mode: ModeConfig, model: any TranscriptionModel)
}

/// The AI provider that runs for a mode's enhancement. The mode list, the mode editor, and each recording all read
/// this, so they always agree. The mode's saved provider is never changed.
enum EnhancementProviderResolution: Equatable {
    /// This provider runs.
    case provider(AIProvider)
    /// The organization blocks the saved provider and offers no provider in its place, so no AI enhancement runs.
    case blocked(AIProvider)
    /// The saved provider isn't connected, or the saved name isn't a known provider.
    case unavailable

    /// The provider that runs, or nil when none does.
    var runningProvider: AIProvider? {
        if case .provider(let provider) = self { return provider }
        return nil
    }

    /// Works out which provider runs, from the mode's saved provider and the organization's settings.
    /// - Parameters:
    ///   - savedProviderName: The mode's saved provider. When nil, the first connected provider runs.
    ///   - lock: The organization's provider lock. When set, its provider always runs.
    ///   - isCloudAllowed: False when the organization turns off cloud services.
    ///   - isAllowed: Whether the organization allows a provider.
    ///   - connectedProviders: The providers this Mac can use, in display order.
    static func resolve(
        savedProviderName: String?,
        lock: EnhancementProviderLock?,
        isCloudAllowed: Bool,
        isAllowed: (AIProvider) -> Bool,
        connectedProviders: [AIProvider]
    ) -> EnhancementProviderResolution {
        if let lock {
            return .provider(lock.provider)
        }
        guard let savedProviderName else {
            return connectedProviders.first.map { .provider($0) } ?? .unavailable
        }
        guard let provider = AIProvider(rawValue: savedProviderName) else {
            return .unavailable
        }
        if !isCloudAllowed, provider.supportsEnhancement {
            if !isAllowed(provider) {
                // Use the organization's provider in place of a blocked one.
                return isAllowed(.managed) ? .provider(.managed) : .blocked(provider)
            }
            if provider == .custom {
                return .provider(provider)
            }
        }
        return connectedProviders.contains(provider) ? .provider(provider) : .unavailable
    }
}

@MainActor
enum ModeRuntimeResolver {
    /// The provider that runs for a mode, with the organization's settings on this Mac.
    /// - Parameters:
    ///   - connectedProviders: The providers this Mac can use. Defaults to `aiService.connectedProviders`.
    static func enhancementProviderResolution(
        savedProviderName: String?,
        savedModelName: String?,
        lock: EnhancementProviderLock? = EnhancementProviderLock.current,
        connectedProviders: [AIProvider]
    ) -> EnhancementProviderResolution {
        EnhancementProviderResolution.resolve(
            savedProviderName: savedProviderName,
            lock: lock,
            isCloudAllowed: CloudPolicy.isCloudAllowed,
            isAllowed: { provider in
                if provider == .custom {
                    let baseURL = savedModelName.flatMap {
                        CustomAIProviderManager.shared.requestConfiguration(forModel: $0)?.baseURL
                    }
                    return CloudPolicy.isEnhancementProviderAllowed(.custom, customBaseURL: baseURL)
                }
                return CloudPolicy.isEnhancementProviderAllowed(provider)
            },
            connectedProviders: connectedProviders
        )
    }

    static func transcriptionModelResolution(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> ModeTranscriptionModelResolution {
        guard let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration else {
            return .noMode
        }

        guard let modelName = mode.selectedTranscriptionModelName,
            !modelName.isEmpty
        else {
            return .noSelection(mode: mode)
        }

        guard
            let model = TranscriptionModelRegistry.model(
                forSelectionKey: modelName,
                in: transcriptionModelManager.allAvailableModels
            )
        else {
            return .modelNotFound(mode: mode)
        }

        // A mode set to a cloud model uses a local model while cloud services are off, or fails if none is downloaded.
        guard CloudPolicy.isTranscriptionAllowed(model) else {
            if let fallback = transcriptionModelManager.cloudPolicyFallbackModel {
                return .available(mode: mode, model: fallback)
            }
            return .unavailable(mode: mode, model: model)
        }

        guard transcriptionModelManager.usableModels.contains(where: {
            $0.selectionKey == model.selectionKey
        }) else {
            return .unavailable(mode: mode, model: model)
        }

        return .available(mode: mode, model: model)
    }

    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        transcriptionConfiguration(
            from: transcriptionModelResolution(
                mode: mode,
                transcriptionModelManager: transcriptionModelManager
            )
        )
    }

    static func transcriptionConfiguration(
        from resolution: ModeTranscriptionModelResolution
    ) -> TranscriptionRuntimeConfiguration? {
        guard
            case .available(let mode, let model) = resolution
        else {
            return nil
        }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode.selectedLanguage,
            for: model,
            realtimeEnabled: mode.isRealtimeTranscriptionEnabled
        )

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(
                for: model, modeValue: mode.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled
                ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        // With the organization's provider lock, every mode uses the locked provider. The mode's saved provider is
        // left as is.
        let lock = EnhancementProviderLock.current
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            configuredModelName: mode?.selectedAIModel,
            lock: lock,
            aiService: aiService
        )
        let configuredModelName = provider.flatMap { provider in
            EnhancementProviderLock.runningModelName(
                provider: provider, savedProvider: mode?.selectedAIProvider, savedModel: mode?.selectedAIModel,
                lock: lock, selectedModel: { aiService.selectedModel(for: $0) })
        }
        let prompt =
            provider == .voiceInkRefine
            ? nil
            : resolvedPrompt(
                promptId: mode?.selectedPrompt,
                enhancementService: enhancementService
            )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: configuredModelName,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: provider == .voiceInkRefine ? false : mode?.useClipboardContext ?? false,
            useSelectedTextContext: provider == .voiceInkRefine ? false : mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: provider == .voiceInkRefine ? false : mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            autoSendKey: mode?.outputMode == .paste ? (mode?.autoSendKey ?? .none) : .none,
            customCommand: mode?.customCommand
        )
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
            let uuid = UUID(uuidString: promptId)
        else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    static func resolvedProvider(
        providerName: String?,
        configuredModelName: String? = nil,
        lock: EnhancementProviderLock? = nil,
        aiService: AIService
    ) -> AIProvider? {
        switch enhancementProviderResolution(
            savedProviderName: providerName,
            savedModelName: configuredModelName,
            lock: lock,
            connectedProviders: aiService.connectedProviders
        ) {
        case .provider(let provider):
            return provider
        case .blocked(let provider):
            // Keep the blocked provider so the request path refuses it and tells the user, rather than skipping
            // enhancement without a word.
            return provider
        case .unavailable:
            return nil
        }
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        if provider == .voiceInkRefine {
            return provider.defaultModel
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
            !configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (provider.supportsCustomModelID || models.isEmpty || models.contains(configuredModelName))
        {
            return configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }
}
