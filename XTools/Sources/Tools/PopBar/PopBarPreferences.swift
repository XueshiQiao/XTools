import Foundation

/// PopBar's own persistence (kept inside the tool's folder, per the XTools
/// convention that tools own their state). App-wide prefs live in `Preferences`.
enum PopBarPreferences {

    private static let enabledKey = "popbar.enabled"
    private static let autoExpandHeightKey = "popbar.autoExpandHeight"
    private static let resultFontSizeKey = "popbar.resultFontSize"

    /// Allowed range + default for the result Markdown's base font size (issue #14).
    /// The user found the old ~12pt body too small, so the default is a touch larger.
    static let resultFontSizeRange: ClosedRange<Double> = 11...20
    static let resultFontSizeDefault: Double = 13

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

    /// The base font size for the result Markdown (issue #14). Absent key → the
    /// default (13). Stored as a Double; clamped to the allowed range on read so a
    /// stale/out-of-range value can never blow up the layout.
    static var resultFontSize: Double {
        get {
            guard UserDefaults.standard.object(forKey: resultFontSizeKey) != nil else {
                return resultFontSizeDefault
            }
            let raw = UserDefaults.standard.double(forKey: resultFontSizeKey)
            return min(max(raw, resultFontSizeRange.lowerBound), resultFontSizeRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, resultFontSizeRange.lowerBound), resultFontSizeRange.upperBound)
            UserDefaults.standard.set(clamped, forKey: resultFontSizeKey)
        }
    }
}
