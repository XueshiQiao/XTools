import AppKit
import Carbon.HIToolbox

/// Synthesizes a global ⌘C keystroke via CGEvent — the engine behind the
/// clipboard-copy fallback. Requires the Accessibility permission (which the
/// whole tool already gates on); needs no extra entitlement.
enum KeySender {

    /// Sentinel stamped onto every key event we synthesize (in the event's
    /// `eventSourceUserData` field), so our OWN `GlobalInputMonitor` can tell our
    /// synthetic ⌘C apart from a real user keystroke. Without it the monitor sees our
    /// ⌘C as a user keyDown and dismisses the very popup we're about to show (this is
    /// what made a triple-click in an AX-opaque app like WeChat — which goes through
    /// the ⌘C fallback — pop then vanish). A fixed, app-unique magic number ("XTOOLS").
    static let syntheticUserData: Int64 = 0x5854_4F4F_4C53

    /// Post ⌘C to the system, where it lands on whatever app is frontmost.
    static func copy() {
        postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    private static func postKeyCombo(virtualKey: CGKeyCode, flags: CGEventFlags) {
        // .combinedSessionState so the synthesized event merges with the user's
        // real modifier state cleanly.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        // Tag both events so we can recognize and ignore them in our global monitor.
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
