import Foundation
import os

/// The key a person got by signing in with Equisolve, and the account name to show for it.
struct ManagedAISignedInKey: Codable, Equatable {
    let apiKey: String
    let keyAlias: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case keyAlias = "key_alias"
    }
}

/// Saves the signed-in key in the Keychain as one item that never syncs to other Macs. The Hourglass access token used
/// to get the key is never saved.
final class ManagedAIKeyStore {
    static let shared = ManagedAIKeyStore()

    /// The Keychain account name of the item.
    static let keychainKey = "ManagedAISignedInKey"

    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedAIKeyStore")

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
    }

    func load() -> ManagedAISignedInKey? {
        guard let data = keychain.getData(forKey: Self.keychainKey, syncable: false) else { return nil }
        guard let key = try? JSONDecoder().decode(ManagedAISignedInKey.self, from: data), !key.apiKey.isEmpty else {
            logger.error("The saved organization AI key couldn't be read")
            return nil
        }
        return key
    }

    @discardableResult
    func save(_ key: ManagedAISignedInKey) -> Bool {
        guard let data = try? JSONEncoder().encode(key) else { return false }
        let saved = keychain.save(
            data: data, forKey: Self.keychainKey, syncable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        if saved { postChange() }
        return saved
    }

    @discardableResult
    func delete() -> Bool {
        let deleted = keychain.delete(forKey: Self.keychainKey, syncable: false)
        if deleted { postChange() }
        return deleted
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .managedAISignInDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread when the signed-in organization AI key is saved or deleted.
    static let managedAISignInDidChange = Notification.Name("managedAISignInDidChange")
}
