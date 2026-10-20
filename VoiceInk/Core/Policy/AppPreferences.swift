import Foundation

/// The preferences domain that organization policy, the managed AI endpoint, and the AI provider selection are read
/// from. In the app it's `UserDefaults.standard`, where a configuration profile's values win. The test bundle
/// replaces it with a suite before any test runs, so tests never write the app's own preferences.
enum AppPreferences {
    static var defaults: UserDefaults = .standard
}
