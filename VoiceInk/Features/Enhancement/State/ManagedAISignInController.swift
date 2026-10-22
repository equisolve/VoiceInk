import AppKit
import Foundation
import os

/// The sign-in state the organization provider's card shows, and the Sign In and Sign Out actions.
@MainActor
final class ManagedAISignInController: ObservableObject {
    static let shared = ManagedAISignInController()

    /// The account the saved key belongs to, or nil when nobody is signed in.
    @Published private(set) var keyAlias: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var errorMessage: String?

    private let keyStore: ManagedAIKeyStore
    private var signInTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedAISignIn")

    init(keyStore: ManagedAIKeyStore = .shared) {
        self.keyStore = keyStore
        keyAlias = keyStore.load()?.keyAlias
        observer = NotificationCenter.default.addObserver(
            forName: .managedAISignInDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        keyAlias = keyStore.load()?.keyAlias
    }

    /// Opens the sign-in page in the default browser and saves the key when the person finishes.
    func signIn(signInURL: URL) {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil

        signInTask = Task { [weak self, keyStore, logger] in
            do {
                let key = try await ManagedAISignInClient.signIn(signInURL: signInURL) { url in
                    NSWorkspace.shared.open(url)
                }
                guard keyStore.save(key) else {
                    self?.finish(error: String(localized: "VoiceInk couldn't save your key in the Keychain."))
                    return
                }
                logger.info("Signed in to the organization AI endpoint")
                self?.keyAlias = key.keyAlias
                self?.finish(error: nil)
            } catch is CancellationError {
                self?.finish(error: nil)
            } catch {
                logger.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
                self?.finish(error: error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Deletes the saved key. The key stays valid on the server until it's revoked in Hourglass.
    func signOut() {
        cancelSignIn()
        keyStore.delete()
        keyAlias = nil
        errorMessage = nil
    }

    private func finish(error: String?) {
        isSigningIn = false
        errorMessage = error
        signInTask = nil
    }
}
