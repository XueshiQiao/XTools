import Foundation

/// PopBar's own persistence (kept inside the tool's folder, per the XTools
/// convention that tools own their state). App-wide prefs live in `Preferences`.
enum PopBarPreferences {

    private static let enabledKey = "popbar.enabled"
    private static let autoExpandHeightKey = "popbar.autoExpandHeight"

    /// Whether the popup is active. Opt-in: defaults to off (absent key → false),
    /// so the tool never starts monitoring global input until the user turns it on.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether the result panel auto-grows its HEIGHT to fit the content (up to a
    /// max, then scrolls). Opt-in: defaults to off (absent key → false), so the
    /// result panel keeps its fixed compact size unless the user turns this on.
    /// Width is always fixed.
    static var autoExpandHeight: Bool {
        get { UserDefaults.standard.bool(forKey: autoExpandHeightKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoExpandHeightKey) }
    }
}
