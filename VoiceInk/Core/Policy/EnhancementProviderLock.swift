import Foundation
import SwiftUI

/// The AI enhancement provider an organization fixes with `LockEnhancementProvider`.
///
/// When the Boolean key is true and `DefaultEnhancementProvider` resolves to a provider this Mac can use, every mode
/// uses that provider, whatever provider the mode has saved. Modes keep their saved provider, so removing the key
/// restores it. When `DefaultEnhancementProvider` names the organization endpoint and the endpoint can't be used, the
/// lock falls back to VoiceInk Refine the same way the default does. When neither can be used, nothing is locked.
struct EnhancementProviderLock: Equatable {
    static let key = "LockEnhancementProvider"

    let provider: AIProvider
    /// The model the organization chose for the provider, or nil to use the provider's selected model.
    let model: String?

    /// The lock, or nil when the key is off or no usable provider resolves. `ignored` explains each value that was
    /// skipped, for the log.
    static func resolve(
        defaults: UserDefaults,
        isCloudAllowed: Bool,
        voiceInkRefineUnavailableReason: String?,
        managedEndpoint: ManagedAIEndpoint?
    ) -> (lock: EnhancementProviderLock?, ignored: [String]) {
        guard defaults.bool(forKey: key) else { return (nil, []) }

        let managed = ManagedDefaults(defaults: defaults)
        guard managed.enhancementProvider != nil else {
            return (nil, ["\(key) is ignored because \(ManagedDefaults.enhancementProviderKey) isn't set"])
        }

        let resolution = ManagedDefaultsResolution(
            ManagedDefaults(enhancementProvider: managed.enhancementProvider, enhancementModel: managed.enhancementModel),
            transcriptionModels: [],
            isCloudAllowed: isCloudAllowed,
            voiceInkRefineUnavailableReason: voiceInkRefineUnavailableReason,
            managedEndpoint: managedEndpoint
        )
        guard let provider = resolution.enhancementProvider else {
            return (nil, resolution.ignored + ["\(key) is ignored because no usable provider resolved"])
        }
        return (EnhancementProviderLock(provider: provider, model: resolution.enhancementModel), resolution.ignored)
    }

    /// The lock for this Mac's preferences, cloud policy, and organization endpoint.
    static var current: EnhancementProviderLock? {
        resolve(
            defaults: AppPreferences.defaults,
            isCloudAllowed: CloudPolicy.isCloudAllowed,
            voiceInkRefineUnavailableReason: VoiceInkRefineService.shared.unavailableDescription,
            managedEndpoint: ManagedAIEndpoint.current
        ).lock
    }

    /// The heading for the lock notice: a profile forces the key, while a key set with `defaults write` doesn't.
    static var noticeTitle: LocalizedStringKey {
        AppPreferences.defaults.objectIsForced(forKey: key) ? "Managed by your organization" : "Set in preferences"
    }

    /// The model a mode uses with the locked provider. The organization's model wins; otherwise the mode's saved
    /// model is kept when the mode already uses the locked provider.
    static func effectiveModelName(
        savedProvider: String?, savedModel: String?, lock: EnhancementProviderLock?
    ) -> String? {
        guard let lock else { return savedModel }
        if let model = lock.model { return model }
        return savedProvider == lock.provider.rawValue ? savedModel : nil
    }
}

/// What the AI model rows and chips show for a provider.
enum EnhancementModelDisplay {
    /// The organization endpoint uses `ManagedAIModel`, which the person can't change, so it has no model picker.
    static func showsModelPicker(for provider: AIProvider) -> Bool {
        provider != .managed
    }

    /// The text of the AI model chip on a mode card, or nil for no chip. The organization endpoint shows the provider
    /// name, because its model name is an internal alias.
    static func chipLabel(providerName: String?, modelName: String?) -> String? {
        let provider = providerName.flatMap(AIProvider.init(rawValue:))
        if provider == .localCLI { return nil }
        if provider == .managed { return AIProvider.managed.displayName }
        guard let modelName, !modelName.isEmpty else { return nil }
        return modelName
    }

    /// The text of the AI model chip on a mode card for the provider that runs, or nil for no chip.
    static func chipLabel(
        resolution: EnhancementProviderResolution,
        savedProviderName: String?,
        savedModelName: String?,
        lock: EnhancementProviderLock?
    ) -> String? {
        switch resolution {
        case .provider(let provider):
            // The saved model goes with the saved provider only; another provider runs its own model.
            let modelName = EnhancementProviderLock.effectiveModelName(
                savedProvider: savedProviderName, savedModel: savedModelName, lock: lock)
            let isSavedProvider = lock != nil || savedProviderName == nil || savedProviderName == provider.rawValue
            return chipLabel(providerName: provider.rawValue, modelName: isSavedProvider ? modelName : nil)
        case .blocked:
            return String(localized: "No AI enhancement")
        case .unavailable:
            return chipLabel(providerName: savedProviderName, modelName: savedModelName)
        }
    }
}
