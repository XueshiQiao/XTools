import SwiftUI
import AppKit

/// UI model for the PopBar settings page. Plain main-thread `ObservableObject`
/// (same shape as the other tools' stores). Bridges the settings UI to the
/// long-lived `PopBarController`.
final class PopBarStore: ObservableObject {

    @Published var isEnabled: Bool
    @Published var autoExpandHeight: Bool
    @Published var resultFontSize: Double
    @Published var style: PopBarStyle
    @Published var wheelOuterRadius: Double
    @Published var wheelInnerRadius: Double
    @Published var wheelShowIcons: Bool
    @Published var wheelShowLabels: Bool
    @Published private(set) var isTrusted: Bool

    private let controller: PopBarController

    init(controller: PopBarController) {
        self.controller = controller
        self.isEnabled = PopBarPreferences.isEnabled
        self.autoExpandHeight = PopBarPreferences.autoExpandHeight
        self.resultFontSize = PopBarPreferences.resultFontSize
        self.style = PopBarPreferences.style
        self.wheelOuterRadius = PopBarPreferences.wheelOuterRadius
        self.wheelInnerRadius = PopBarPreferences.wheelInnerRadius
        self.wheelShowIcons = PopBarPreferences.wheelShowIcons
        self.wheelShowLabels = PopBarPreferences.wheelShowLabels
        self.isTrusted = AccessibilityAuthorizer.isTrusted
    }

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

    /// Toggle whether the result panel auto-grows its height to fit content.
    /// Persisted in PopBar's own prefs; the controller pushes it to a live panel
    /// so an already-open result honors the change immediately.
    func setAutoExpandHeight(_ on: Bool) {
        autoExpandHeight = on
        PopBarPreferences.autoExpandHeight = on
        controller.setAutoExpandHeight(on)
    }

    /// Set the result Markdown's base font size (issue #14). Persisted in PopBar's
    /// own prefs; the controller pushes it to every live panel so an already-open
    /// result re-renders at the new size immediately. Mirrors `setAutoExpandHeight`.
    func setResultFontSize(_ size: Double) {
        resultFontSize = size
        PopBarPreferences.resultFontSize = size
        controller.setResultFontSize(size)
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

    /// Switch the popup's presentation style. Persisted in PopBar's own prefs and
    /// reflected live in the centered preview (so flipping capsule ↔ wheel ↔ liquid in
    /// settings shows the new style immediately).
    func setStyle(_ s: PopBarStyle) {
        style = s
        PopBarPreferences.style = s
        controller.previewStyleLive()   // show/refresh the preview so the new style is visible live
    }

    /// Wheel geometry / content settings (wheel + liquid-glass styles). Persisted;
    /// the next popup / Preview reads them at show time. Inner is kept at least
    /// `wheelMinThickness` below outer so the ring stays valid.
    func setWheelOuterRadius(_ r: Double) {
        wheelOuterRadius = r
        PopBarPreferences.wheelOuterRadius = r
        if wheelInnerRadius > r - PopBarPreferences.wheelMinThickness {
            setWheelInnerRadius(r - PopBarPreferences.wheelMinThickness)
        }
        controller.previewWheelLive()
    }
    func setWheelInnerRadius(_ r: Double) {
        let capped = min(r, wheelOuterRadius - PopBarPreferences.wheelMinThickness)
        wheelInnerRadius = capped
        PopBarPreferences.wheelInnerRadius = capped
        controller.previewWheelLive()
    }
    func setWheelShowIcons(_ on: Bool) {
        // Don't let the user hide BOTH icon and label (a slice would be blank).
        if !on && !wheelShowLabels { setWheelShowLabels(true) }
        wheelShowIcons = on
        PopBarPreferences.wheelShowIcons = on
        controller.previewWheelLive()
    }
    func setWheelShowLabels(_ on: Bool) {
        if !on && !wheelShowIcons { setWheelShowIcons(true) }
        wheelShowLabels = on
        PopBarPreferences.wheelShowLabels = on
        controller.previewWheelLive()
    }

    func requestPermission() { AccessibilityAuthorizer.prompt() }
    func openAccessibilitySettings() { AccessibilityAuthorizer.openSettings() }
    func showPreview() { controller.showPreview() }
    /// Hide the live tuning preview when the user leaves the PopBar settings page.
    func dismissPreview() { controller.dismissPreview() }
}
