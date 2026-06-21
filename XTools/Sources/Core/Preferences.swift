import Foundation
import AppKit

/// App-global preferences (language, analytics opt-out, version tracking).
///
/// Each tool owns its OWN persistence inside its folder (e.g. the Launch
/// Manager persists Guardian rules via `GuardianRuleStore`). This keeps tools
/// isolated — `Preferences` only holds things that are genuinely app-wide.
enum Preferences {

    private static let log = FileLog("Preferences")

    enum Key {
        static let languageOverride = "languageOverride"
        static let analyticsEnabled = "analyticsEnabled"
        static let lastSeenVersion  = "lastSeenVersion"
    }

    // MARK: - Language

    /// Read the saved override and install it. Call before any localized string
    /// is read (first thing in `applicationDidFinishLaunching`).
    static func applyLanguageOverride() {
        let saved = UserDefaults.standard.string(forKey: Key.languageOverride) ?? ""
        LocalizationOverride.apply(code: saved.isEmpty ? nil : saved)
    }

    /// Persist + apply a new language override (nil = follow system), then post
    /// `.xtoolsLanguageChanged` so live surfaces rebuild without a relaunch.
    static func setLanguageOverride(_ code: String?) {
        let d = UserDefaults.standard
        if let code, !code.isEmpty {
            d.set(code, forKey: Key.languageOverride)
        } else {
            d.removeObject(forKey: Key.languageOverride)
        }
        LocalizationOverride.apply(code: code)
        Analytics.trackPreferenceChanged(key: "language", value: code ?? "system")
        NotificationCenter.default.post(name: .xtoolsLanguageChanged, object: nil)
    }

    // MARK: - Analytics opt-out

    /// Default true when the key is absent (fresh installs opt in).
    static var analyticsEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: Key.analyticsEnabled) == nil { return true }
        return d.bool(forKey: Key.analyticsEnabled)
    }

    /// Persist the analytics opt-out. Fires the meta-event BEFORE persisting
    /// (it bypasses the opt-out gate) so both directions of the toggle reach the
    /// server, then flushes when turning OFF so the OFF event escapes before the
    /// gate closes.
    static func setAnalyticsEnabled(_ on: Bool) {
        let previous = analyticsEnabled
        if previous != on {
            Analytics.trackPreferenceChanged(key: "analytics_enabled", value: String(on))
        }
        UserDefaults.standard.set(on, forKey: Key.analyticsEnabled)
        if !on { Analytics.flush() }
    }
}
