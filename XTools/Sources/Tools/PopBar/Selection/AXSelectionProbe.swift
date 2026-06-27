import AppKit
import ApplicationServices

/// Shared, cheap Accessibility probes for "is there a text selection right now?".
///
/// One Source of Truth for the AX boilerplate that both `AccessibilityStrategy`
/// (read the selection) and `ClipboardCopyStrategy` (decide whether to even *try*
/// a synthetic ⌘C) would otherwise duplicate.
///
/// The reason this exists is issue #15: the drag-to-select gesture fires on *any*
/// drag — including dragging a Finder icon, a list row, or a window in another
/// app. For those non-text drags the old fallback posted a global ⌘C anyway; with
/// no copyable selection the frontmost app plays the system "funk" beep on the
/// unhandled ⌘C. So before we synthesize ⌘C we ask AX whether a text selection
/// *plausibly* exists, and skip the copy (no beep) when it clearly doesn't.
enum AXSelectionProbe {

    /// The system-wide focused UI element, or nil if none / AX unreadable.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The AX role of an element (e.g. `AXTextField`, `AXTextArea`, `AXWebArea`).
    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Length of the focused element's selected-text range, if it exposes one.
    ///
    /// Returns:
    ///  - `.some(n)` when `kAXSelectedTextRangeAttribute` is a readable `.cfRange`
    ///    (`n` may be 0 for a collapsed caret with no selection);
    ///  - `nil` when the attribute is absent / unreadable (e.g. an app that
    ///    exposes no AX text element at all — a list, an icon, a plain button).
    static func selectedRangeLength(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    /// Whether the focused element exposes a **non-empty** WebKit-style selected
    /// text-marker range. This is the selection signal for Safari/WebViews and —
    /// importantly — for PDF/canvas-style content (e.g. Preview) whose role isn't
    /// a classic text role but which still backs its selection with a marker
    /// range. Used as a positive copy signal so we don't regress those AX-opaque
    /// but genuinely-copyable surfaces (the case Codex flagged on the gate).
    static func hasMarkerSelection(of element: AXUIElement) -> Bool {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return false }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForTextMarkerRange" as CFString, markerRange, &text) == .success,
              let string = text as? String else { return false }
        return !string.isEmpty
    }

    /// AX roles that bear editable / selectable text. Used as a secondary signal
    /// when a range length isn't directly readable but the role still implies the
    /// focus is on text content.
    ///
    /// `AXWebArea` is deliberately NOT here: a web page's focused element is an
    /// `AXWebArea` whether the drag selected text or just dragged an image / link /
    /// empty page area. Treating the role alone as "has text" would re-open the
    /// beep for ordinary non-text drags inside a page. Real WebKit text selections
    /// are caught by the marker-selection branch instead (verified: Safari exposes
    /// a non-empty `AXSelectedTextMarkerRange` for a live selection).
    private static let textBearingRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXStaticTextRole as String,
        "AXSearchField",      // some apps expose this distinct role
    ]

    /// The decision used to gate a synthetic ⌘C.
    struct Decision {
        /// Whether a text selection plausibly exists right now.
        let shouldCopy: Bool
        /// Focused element role (for logging), or "nil" when unreadable.
        let role: String
        /// Selected-range length: `>= 0` when readable, `-1` when unreadable.
        let rangeLength: Int
    }

    /// Decide whether posting ⌘C is worthwhile, i.e. whether the current focus
    /// plausibly holds a TEXT selection.
    ///
    /// Policy (issue #15), in priority order:
    ///  - selected-text range present with **length > 0** → yes, copy;
    ///  - a non-empty **WebKit/PDF marker selection** exists → yes, copy (recovers
    ///    Safari/WebView and PDF/canvas content whose role isn't a classic text
    ///    role — the AX-opaque-but-copyable case Codex flagged);
    ///  - range length **0** (collapsed caret) → no selection → skip;
    ///  - range **unreadable** but the focused role is a **text-bearing role** →
    ///    a few apps expose the role but not a stable range; allow the copy so we
    ///    don't regress real text fields;
    ///  - range unreadable AND role not text-bearing AND no marker selection
    ///    (a list, icon, window, or an app that exposes no AX at all) → **skip**
    ///    the ⌘C. No beep.
    ///
    /// AX-opaque tradeoff (commented intentionally): a custom view that exposes
    /// NO AX selection signal at all (no range, no marker range, non-text role) —
    /// e.g. some Electron apps before `AXManualAccessibility` is set — is treated
    /// as "no selection" and we skip (stay silent). `AccessibilityStrategy`
    /// enables enhanced AX on that first encounter, so the *next* selection reads
    /// via AX directly. We accept one missed first-copy in those rare apps in
    /// exchange for never beeping on the far more common non-text drag. (Skipping
    /// is also what the reference lineage — SelectedTextKit / Easydict / Xpop —
    /// does to avoid this force-copy beep.)
    static func shouldAttemptCopy() -> Decision {
        guard let focused = focusedElement() else {
            // No focused element at all → nothing to copy from. Skip.
            return Decision(shouldCopy: false, role: "nil", rangeLength: -1)
        }
        let roleName = role(of: focused) ?? "nil"
        let length = selectedRangeLength(of: focused)

        // A readable, non-empty selected range is the strongest signal.
        if let length, length > 0 {
            return Decision(shouldCopy: true, role: roleName, rangeLength: length)
        }
        // WebKit/PDF marker selection — covers copyable content with a non-text
        // role (Safari, PDF/canvas) that the plain range can't express.
        if hasMarkerSelection(of: focused) {
            return Decision(shouldCopy: true, role: roleName, rangeLength: length ?? -1)
        }
        // A readable range of length 0 is a definite "caret, no selection".
        if let length {
            return Decision(shouldCopy: false, role: roleName, rangeLength: length)
        }
        // Range unreadable: fall back to the role signal so we don't regress real
        // text fields that hide their range.
        let textBearing = textBearingRoles.contains(roleName)
        return Decision(shouldCopy: textBearing, role: roleName, rangeLength: -1)
    }
}
