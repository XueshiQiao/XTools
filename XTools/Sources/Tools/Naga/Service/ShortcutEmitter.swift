import AppKit
import Carbon.HIToolbox

/// Synthesizes a keystroke via CGEvent — how we emit the *replacement* for a
/// seized side-button press. Carries a sentinel in `eventSourceUserData` so any
/// future event-tap of ours can recognize (and ignore) its own output.
enum ShortcutEmitter {

    /// App-unique magic ("XTOOLS") stamped on every synthesized event.
    static let syntheticUserData: Int64 = 0x5854_4F4F_4C53

    /// Emit a key + modifier flags (macOS virtual keycode space).
    static func emit(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown)
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
            e?.post(tap: .cghidEventTap)
        }
    }
}
