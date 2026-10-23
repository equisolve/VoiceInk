import AppKit
import SwiftUI

/// Sets whether VoiceInk runs from the menu bar without a Dock icon. `LiveManagedDefaultsTarget` uses it for
/// `DefaultMenuBarOnly`; tests use a stand-in.
protocol MenuBarOnlySetting: AnyObject {
    func setMenuBarOnlyKeepingWindows(_ menuBarOnly: Bool)
}

class MenuBarManager: ObservableObject, MenuBarOnlySetting {
    @Published var isMenuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnly, forKey: "IsMenuBarOnly")
            if keepsWindowsOnNextChange {
                keepsWindowsOnNextChange = false
                applyActivationPolicyKeepingWindows()
            } else {
                applyActivationPolicy()
            }
        }
    }

    private var engine: VoiceInkEngine?
    private var keepsWindowsOnNextChange = false

    /// Changes the setting like the Hide Dock Icon toggle, but leaves open windows up. While a window is open, the
    /// Dock icon stays; when the last one closes, `userFacingWindowWillClose` hides the Dock icon, the same as it
    /// does after the person opens a window from the menu bar.
    func setMenuBarOnlyKeepingWindows(_ menuBarOnly: Bool) {
        guard menuBarOnly != isMenuBarOnly else { return }
        keepsWindowsOnNextChange = true
        isMenuBarOnly = menuBarOnly
    }

    private func applyActivationPolicyKeepingWindows() {
        let applyPolicy = { [weak self] in
            guard let self else { return }
            if !self.isMenuBarOnly || WindowDiagnostics.visibleUserFacingWindows().isEmpty {
                NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }
    private var configuredActivationPolicy: NSApplication.ActivationPolicy {
        isMenuBarOnly ? .accessory : .regular
    }

    init() {
        self.isMenuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        applyActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userFacingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func userFacingWindowWillClose(_ notification: Notification) {
        guard isMenuBarOnly,
            let window = notification.object as? NSWindow,
            window.level == .normal,
            window.styleMask.contains(.titled)
        else {
            return
        }

        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed()
    }

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
    }

    func toggleMenuBarOnly() {
        isMenuBarOnly.toggle()
    }

    func applyActivationPolicy() {
        let applyPolicy = { [weak self] in
            guard let self else { return }

            NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)

            if self.isMenuBarOnly {
                WindowManager.shared.hideMainWindow()
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    func activateForPresentedWindow() {
        let activate = {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async(execute: activate)
        }
    }

    func openQuickHistory() {
        guard let engine else { return }

        // Let the MenuBarExtra close before making the nonactivating panel key.
        DispatchQueue.main.async {
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        }
    }
}
