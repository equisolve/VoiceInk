import Foundation

/// Whether VoiceInk may ask the person to star the project on GitHub.
///
/// An administrator hides the request by setting the Boolean `HideGitHubStarPrompt` to true in a configuration
/// profile. When the key is false or absent, the Show GitHub Star Request setting decides.
enum GitHubStarPromptPolicy {
    static let hidePromptKey = "HideGitHubStarPrompt"
    /// The person's own setting. On unless they turn it off.
    static let showPromptKey = "ShowGitHubStarPrompt"

    static var isPromptAllowed: Bool {
        isPromptAllowed(in: AppPreferences.defaults)
    }

    static func isPromptAllowed(in defaults: UserDefaults) -> Bool {
        if isHiddenByPolicy(in: defaults) { return false }
        return defaults.object(forKey: showPromptKey) == nil || defaults.bool(forKey: showPromptKey)
    }

    /// True when `HideGitHubStarPrompt` is true, so the person's setting can't turn the request back on.
    static func isHiddenByPolicy(in defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        defaults.bool(forKey: hidePromptKey)
    }

    /// True when a configuration profile sets the key, so the UI can say the setting is managed.
    static var isManaged: Bool {
        AppPreferences.defaults.objectIsForced(forKey: hidePromptKey)
    }
}
