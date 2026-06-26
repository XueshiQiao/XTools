import SwiftUI
import AppKit

/// UI model for the PopBar settings page. Plain main-thread `ObservableObject`
/// (same shape as the other tools' stores). Bridges the settings UI to the
/// long-lived `PopBarController`.
final class PopBarStore: ObservableObject {

    @Published var isEnabled: Bool
    @Published private(set) var isTrusted: Bool

    private let controller: PopBarController

    init(controller: PopBarController) {
        self.controller = controller
        self.isEnabled = PopBarPreferences.isEnabled
        self.isTrusted = AccessibilityAuthorizer.isTrusted
    }

    /// All built-in actions, for the preview list.
    var actions: [PopBarAction] { ActionRegistry.defaults }

    /// Turn the popup on/off. Turning on without permission persists the choice
    /// and prompts; monitoring then auto-starts once permission is granted (see
    /// `refreshTrust`).
    func setEnabled(_ on: Bool) {
        isEnabled = on
        PopBarPreferences.isEnabled = on
        if on {
            if isTrusted {
                controller.start()
            } else {
                AccessibilityAuthorizer.prompt()
            }
        } else {
            controller.stop()
        }
    }

    /// Re-check the Accessibility grant (the user may toggle it in System
    /// Settings while we run); start monitoring if it just became available.
    func refreshTrust() {
        let trusted = AccessibilityAuthorizer.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        if trusted && isEnabled && !controller.isRunning {
            controller.start()
        }
    }

    func requestPermission() { AccessibilityAuthorizer.prompt() }
    func openAccessibilitySettings() { AccessibilityAuthorizer.openSettings() }
    func showPreview() { controller.showPreview() }
}
