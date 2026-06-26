import AppKit
import Carbon.HIToolbox

/// Synthesizes a global ⌘C keystroke via CGEvent — the engine behind the
/// clipboard-copy fallback. Requires the Accessibility permission (which the
/// whole tool already gates on); needs no extra entitlement.
enum KeySender {

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
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
