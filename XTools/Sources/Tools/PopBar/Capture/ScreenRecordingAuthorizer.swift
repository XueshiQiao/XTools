import CoreGraphics
import AppKit

/// Thin wrapper around the Screen Recording (TCC) permission that screen capture
/// needs — without it capture APIs return black / desktop-only pixels.
enum ScreenRecordingAuthorizer {

    /// Whether the app currently has the Screen Recording permission. Cheap; safe
    /// to poll. Does not prompt.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Trigger the system's "grant Screen Recording access" prompt. Returns the
    /// current authorization state.
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Open System Settings → Privacy & Security → Screen Recording.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
