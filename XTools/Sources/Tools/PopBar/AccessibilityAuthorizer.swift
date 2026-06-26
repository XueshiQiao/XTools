import AppKit
import ApplicationServices

/// Thin wrapper around the Accessibility (process-trust) permission that the
/// whole tool depends on: without it we can neither monitor global input nor read
/// the selection. No extra entitlement is involved — just this TCC grant.
enum AccessibilityAuthorizer {

    /// Whether the app currently has the Accessibility permission. Cheap; safe to
    /// poll. Does not prompt.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Trigger the system's "grant Accessibility access" prompt (only shows once
    /// per app until the user acts on it).
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
