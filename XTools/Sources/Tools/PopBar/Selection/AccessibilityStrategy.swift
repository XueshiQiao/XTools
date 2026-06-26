import AppKit
import ApplicationServices

/// The primary, preferred way to read the selection: the macOS Accessibility
/// API. Fast, side-effect-free (doesn't touch the clipboard), and works in
/// native text fields out of the box.
///
/// Two reads, in order:
///  1. `kAXSelectedTextAttribute` on the focused element — native AppKit text.
///  2. `AXStringForTextMarkerRange` over `AXSelectedTextMarkerRange` — the WebKit
///     path, for Safari and other browser/WebKit content.
///
/// Electron/Chromium apps (VS Code, Slack, Discord, Chrome) don't expose their
/// accessibility tree by default, so the first read returns nothing. When that
/// happens we set `AXManualAccessibility` / `AXEnhancedUserInterface` on the app
/// once, which opens the tree for subsequent reads (the fallback strategy covers
/// the current read in the meantime).
final class AccessibilityStrategy: SelectionStrategy {

    let id = SelectionStrategyID.accessibility
    private static let log = FileLog("PopBar.AX")

    /// Apps we've already tried to AX-enable, so we only poke each once.
    private var enabledPIDs = Set<pid_t>()

    func selectedText(_ context: SelectionContext) async throws -> SelectionResult? {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionDenied }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) else {
            enableEnhancedAXIfNeeded(context)
            throw SelectionError.noFocusedElement
        }

        // 1) Plain selected-text attribute.
        if let text = copyString(focused, kAXSelectedTextAttribute), !text.isEmpty {
            return SelectionResult(text: text, via: id, bounds: selectionBounds(focused))
        }

        // 2) WebKit text-marker range (browsers / WebViews).
        if let text = textViaMarkerRange(focused), !text.isEmpty {
            return SelectionResult(text: text, via: id, bounds: selectionBounds(focused))
        }

        // Empty: this app may simply not expose AX yet (Electron/Chromium).
        // Open it for next time; this read falls through to the clipboard strategy.
        enableEnhancedAXIfNeeded(context)
        return nil
    }

    // MARK: - AX helpers

    /// Copy an attribute that is itself an AXUIElement (e.g. the focused element).
    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Copy a string-valued attribute.
    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    /// The WebKit selected-text path: read the selected text-marker range, then
    /// resolve it to a string. These attribute names are private but stable and
    /// are what every PopClip-style tool uses for browser content.
    private func textViaMarkerRange(_ element: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return nil }

        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, markerRange, &text) == .success else { return nil }
        return text as? String
    }

    /// Best-effort on-screen rect of the selection (top-left origin, screen
    /// pixels). Captured for logging / future precise placement; v1 anchors the
    /// popup on the cursor, so a failure here is harmless.
    private func selectionBounds(_ element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
              let boundsValue else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect == .zero ? nil : rect
    }

    /// Open an app's accessibility tree (Electron/Chromium) — once per app.
    private func enableEnhancedAXIfNeeded(_ context: SelectionContext) {
        guard let pid = context.pid, !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Self.log.info("enabled enhanced AX for \(context.bundleID ?? "pid \(pid)")")
    }
}
