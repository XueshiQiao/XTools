import Foundation
import Aptabase

/// Thin facade over the Aptabase SDK. All call sites go through this enum so the
/// rest of the codebase never imports `Aptabase` directly and the opt-out gate
/// lives in exactly one place.
///
/// SCAFFOLDING NOTE: `appKey` is a placeholder. Until you create an Aptabase
/// project and paste its real key here, `start()` skips initialization and every
/// event is a silent no-op — the facade is wired up but inert, so nothing leaves
/// the device. Replace `appKey`, ship, and it goes live.
///
/// Privacy contract:
/// - No bundle IDs, process names, or paths ever leave the device.
/// - All events are gated on `Preferences.Key.analyticsEnabled` (default true)
///   EXCEPT the meta-event recording the toggle itself, so an OFF→ON re-enable
///   stays observable.
enum Analytics {

    private static let log = FileLog("Analytics")

    /// PLACEHOLDER — replace with the real Aptabase app key (format "A-XX-0000000000").
    private static let appKey = "A-XX-0000000000"

    private static var started = false

    /// True only once a real (non-placeholder) key has been configured.
    private static var isConfigured: Bool {
        !appKey.isEmpty && !appKey.hasPrefix("A-XX-")
    }

    // MARK: - Lifecycle

    static func start() {
        guard !started else { return }
        guard isConfigured else {
            log.info("analytics inert — placeholder appKey; events are no-ops")
            return
        }
        started = true
        Aptabase.shared.initialize(appKey: appKey)
        track("app_launched")
        trackUpdateInstalledIfNeeded()
    }

    static func flush() {
        guard started else { return }
        Aptabase.shared.flush()
    }

    // MARK: - Events

    static func trackToolOpened(_ toolID: String) {
        track("tool_opened", with: ["tool": toolID])
    }

    /// A Launch-Manager reap/disable action. `kind` is the action (reap / bootout
    /// / disable_plist), `scope` is user|root. No process names are sent.
    static func trackLaunchAction(kind: String, scope: String) {
        track("launch_action", with: ["kind": kind, "scope": scope])
    }

    static func trackPreferenceChanged(key: String, value: String) {
        if key == "analytics_enabled" {
            sendDirect("preference_changed", props: ["key": key, "value": value])
            return
        }
        track("preference_changed", with: ["key": key, "value": value])
    }

    // MARK: - Update detection

    private static func trackUpdateInstalledIfNeeded() {
        let d = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = d.string(forKey: Preferences.Key.lastSeenVersion)
        if let last, !last.isEmpty, last != current {
            track("update_installed", with: ["from_version": last, "to_version": current])
        }
        if !current.isEmpty { d.set(current, forKey: Preferences.Key.lastSeenVersion) }
    }

    // MARK: - Internals

    private static func track(_ name: String) {
        guard started, Preferences.analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name)
    }

    private static func track(_ name: String, with props: [String: String]) {
        guard started, Preferences.analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }

    /// Gate-bypassing send (used only for the analytics_enabled toggle event so
    /// both directions of the toggle reach the server).
    private static func sendDirect(_ name: String, props: [String: String]) {
        guard started else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }
}
