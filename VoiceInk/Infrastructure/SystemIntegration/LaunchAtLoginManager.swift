import Combine
import Foundation
import ServiceManagement
import os

/// The login item that opens VoiceInk at login. `MainAppLoginItem` uses `SMAppService.mainApp`; tests use a
/// stand-in.
protocol LoginItem: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItem: LoginItem {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false

    private let loginItem: any LoginItem
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LaunchAtLogin")
    private var isRefreshing = false
    private var operationGeneration = 0
    /// Counts calls to `setEnabled(_:)`, so `setEnabledAndWait(_:)` can tell when a later change replaced its own.
    private var setEnabledCount = 0
    private var pendingEnabledState: Bool?
    private var updateTask: Task<Void, Never>?

    init(loginItem: any LoginItem = MainAppLoginItem()) {
        self.loginItem = loginItem
        refresh()
    }

    func refresh() {
        guard !isRefreshing, !isUpdating else { return }

        isRefreshing = true
        let generation = operationGeneration

        Task {
            let enabled = await readStatus() == .enabled
            isRefreshing = false

            guard generation == operationGeneration else { return }
            isEnabled = enabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        operationGeneration += 1
        setEnabledCount += 1
        isEnabled = enabled
        pendingEnabledState = enabled

        guard updateTask == nil else { return }

        isUpdating = true
        updateTask = Task { [weak self] in
            await self?.applyPendingEnabledStates()
        }
    }

    /// Calls `setEnabled(_:)` and waits for the change to finish. Returns false when the login item couldn't be
    /// registered or removed. Returns true when it was, and when another `setEnabled(_:)` call, such as the person
    /// using the toggle, replaced this change before it finished. A login item that waits for the person's approval
    /// in System Settings counts as registered, because the person decides there.
    func setEnabledAndWait(_ enabled: Bool) async -> Bool {
        setEnabled(enabled)
        let count = setEnabledCount
        while let updateTask {
            await updateTask.value
        }

        if setEnabledCount != count {
            return true
        }

        let status = await readStatus()
        if enabled, status == .requiresApproval {
            logger.notice("Launch at login is registered and waits for approval in System Settings")
        }
        return enabled ? status == .enabled || status == .requiresApproval : status != .enabled
    }

    func currentEnabledStatus() async -> Bool {
        operationGeneration += 1

        while true {
            let generation = operationGeneration

            if let updateTask {
                await updateTask.value
                continue
            }

            let enabled = await readStatus() == .enabled
            guard generation == operationGeneration, updateTask == nil else {
                continue
            }

            isEnabled = enabled
            return enabled
        }
    }

    private func applyPendingEnabledStates() async {
        while let enabled = pendingEnabledState {
            pendingEnabledState = nil
            let result = await updateRegistration(enabled: enabled)

            if pendingEnabledState == nil {
                isEnabled = result.isEnabled
            }

            if let errorDescription = result.errorDescription {
                logger.error(
                    "Failed to \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(errorDescription, privacy: .public)"
                )
            }
        }

        isUpdating = false
        updateTask = nil
    }

    private func readStatus() async -> SMAppService.Status {
        let loginItem = loginItem
        return await Task.detached(priority: .utility) {
            loginItem.status
        }.value
    }

    private func updateRegistration(enabled: Bool) async -> UpdateResult {
        let loginItem = loginItem
        return await Task.detached(priority: .utility) {
            do {
                if enabled {
                    if loginItem.status != .enabled {
                        try loginItem.register()
                    }
                } else if loginItem.status != .notRegistered {
                    try loginItem.unregister()
                }
            } catch {
                return UpdateResult(
                    isEnabled: loginItem.status == .enabled,
                    errorDescription: error.localizedDescription
                )
            }

            return UpdateResult(
                isEnabled: loginItem.status == .enabled,
                errorDescription: nil
            )
        }.value
    }

    private struct UpdateResult: Sendable {
        let isEnabled: Bool
        let errorDescription: String?
    }
}
