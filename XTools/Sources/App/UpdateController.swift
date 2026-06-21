import AppKit
import Sparkle

/// Owns Sparkle's updater and bridges the menu-bar / About-page
/// "Check for Updates…" actions to it.
///
/// XTools is an accessory (`LSUIElement`) app, so it is never frontmost on its
/// own. Sparkle activates background apps when showing update UI, but on
/// macOS 14+ `[NSApp activate]` is cooperative — the system routinely defers it,
/// so the update window can open behind another app. As the user-driver delegate
/// we additionally force the window above other apps with `orderFrontRegardless()`,
/// but only for user-initiated checks so scheduled background reminders stay gentle.
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {

    private var updaterController: SPUStandardUpdaterController!

    private var userInitiatedSession = false
    private var raiseTimer: Timer?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        userInitiatedSession = canCheckForUpdates
        updaterController.checkForUpdates(sender)
        if userInitiatedSession {
            bringUpdateWindowToFront()
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    // MARK: - SPUStandardUserDriverDelegate

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        userInitiatedSession = state.userInitiated
        if state.userInitiated {
            bringUpdateWindowToFront()
        }
    }

    func standardUserDriverWillShowModalAlert() {
        if userInitiatedSession {
            bringUpdateWindowToFront()
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        userInitiatedSession = false
        raiseTimer?.invalidate()
        raiseTimer = nil
    }

    // MARK: - Front-ordering

    private func bringUpdateWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)

        raiseTimer?.invalidate()
        var fires = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            fires += 1
            self?.raiseUpdateWindows()
            if fires >= 4 {
                timer.invalidate()
                self?.raiseTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        raiseTimer = timer
    }

    private func raiseUpdateWindows() {
        for window in NSApp.windows where window.isVisible && !isOwnedByApp(window) {
            window.orderFrontRegardless()
        }
    }

    /// A window "belongs to XTools" if it's one of our own NSWindow subclasses or
    /// a plain window we drive via our own controller. Sparkle's windows live in
    /// its framework bundle and AppKit's NSAlert in AppKit's — neither matches.
    private func isOwnedByApp(_ window: NSWindow) -> Bool {
        if Bundle(for: type(of: window)) == .main { return true }
        if let controller = window.windowController,
           Bundle(for: type(of: controller)) == .main { return true }
        return false
    }
}
