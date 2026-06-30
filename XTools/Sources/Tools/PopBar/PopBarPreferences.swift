import Foundation
import CoreGraphics

/// How the popup presents its action row. The trigger/LLM core is identical for
/// both — only the UI and window placement differ (capsule = horizontal bar above
/// the selection; wheel = a ring centered on the cursor).
enum PopBarStyle: String, CaseIterable, Hashable {
    case capsule
    case wheel
    case liquidGlass
    /// Ring-based styles (wheel + liquid glass): centered on the cursor, only the
    /// ring hit-tests. The shell treats them the same for placement / hit-testing;
    /// they differ only in their SwiftUI skin.
    var isWheel: Bool { self == .wheel || self == .liquidGlass }
}

/// PopBar's own persistence (kept inside the tool's folder, per the XTools
/// convention that tools own their state). App-wide prefs live in `Preferences`.
enum PopBarPreferences {

    private static let enabledKey = "popbar.enabled"
    private static let autoExpandHeightKey = "popbar.autoExpandHeight"
    private static let resultFontSizeKey = "popbar.resultFontSize"
    private static let styleKey = "popbar.style"
    private static let wheelOuterRadiusKey = "popbar.wheel.outerRadius"
    private static let wheelInnerRadiusKey = "popbar.wheel.innerRadius"
    private static let wheelShowIconsKey = "popbar.wheel.showIcons"
    private static let wheelShowLabelsKey = "popbar.wheel.showLabels"
    private static let wheelAutoHideOnExitKey = "popbar.wheel.autoHideOnExit"

    /// Allowed range + default for the result Markdown's base font size (issue #14).
    /// The user found the old ~12pt body too small, so the default is a touch larger.
    static let resultFontSizeRange: ClosedRange<Double> = 11...20
    static let resultFontSizeDefault: Double = 13

    /// Wheel geometry knobs (apply to both the wheel + liquid-glass styles). Defaults
    /// match the locked design; inner is kept at least `wheelMinThickness` below outer.
    static let wheelOuterRadiusRange: ClosedRange<Double> = 90...170
    static let wheelInnerRadiusRange: ClosedRange<Double> = 28...140
    static let wheelMinThickness: Double = 26
    static let wheelOuterRadiusDefault: Double = 114
    static let wheelInnerRadiusDefault: Double = 54

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

    /// Which presentation the popup uses. Absent/unknown key → `.capsule` (the
    /// original, so existing users are unaffected). Stored as the enum's raw string.
    static var style: PopBarStyle {
        get { PopBarStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .capsule }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
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

    // MARK: - Wheel geometry / content (wheel + liquid-glass styles)

    private static func double(_ key: String, default def: Double, in range: ClosedRange<Double>) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return def }
        return min(max(UserDefaults.standard.double(forKey: key), range.lowerBound), range.upperBound)
    }
    private static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    static var wheelOuterRadius: Double {
        get { double(wheelOuterRadiusKey, default: wheelOuterRadiusDefault, in: wheelOuterRadiusRange) }
        set { UserDefaults.standard.set(min(max(newValue, wheelOuterRadiusRange.lowerBound), wheelOuterRadiusRange.upperBound), forKey: wheelOuterRadiusKey) }
    }
    static var wheelInnerRadius: Double {
        get { double(wheelInnerRadiusKey, default: wheelInnerRadiusDefault, in: wheelInnerRadiusRange) }
        set { UserDefaults.standard.set(min(max(newValue, wheelInnerRadiusRange.lowerBound), wheelInnerRadiusRange.upperBound), forKey: wheelInnerRadiusKey) }
    }
    static var wheelShowIcons: Bool {
        get { bool(wheelShowIconsKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: wheelShowIconsKey) }
    }
    static var wheelShowLabels: Bool {
        get { bool(wheelShowLabelsKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: wheelShowLabelsKey) }
    }
    /// Auto-hide the ring (wheel + liquid-glass only) when the pointer moves outside
    /// it. Opt-out; default ON. The capsule style ignores this.
    static var wheelAutoHideOnExit: Bool {
        get { bool(wheelAutoHideOnExitKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: wheelAutoHideOnExitKey) }
    }

    /// A `WheelLayout` built from the current prefs. Inner is clamped to stay at least
    /// `wheelMinThickness` below outer so the ring is always valid regardless of the
    /// stored values (e.g. if the user shrinks outer below a large inner).
    static var wheelLayout: WheelLayout {
        let outer = wheelOuterRadius
        let inner = min(wheelInnerRadius, outer - wheelMinThickness)
        return WheelLayout(outerRadius: CGFloat(outer), innerRadius: CGFloat(inner),
                           showIcons: wheelShowIcons, showLabels: wheelShowLabels)
    }
}
