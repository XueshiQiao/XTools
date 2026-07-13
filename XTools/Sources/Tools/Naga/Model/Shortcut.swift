import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut to emit as a side button's replacement: a macOS virtual
/// keycode plus modifier flags. A single key is a shortcut with no modifiers.
struct Shortcut: Codable, Equatable {
    let keyCode: UInt16          // CGKeyCode / kVK_*
    let modifiers: UInt          // NSEvent.ModifierFlags.rawValue (device-independent subset)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// The modifier flags in CGEvent terms, for synthesizing the keystroke.
    var cgFlags: CGEventFlags {
        var c = CGEventFlags()
        if flags.contains(.command) { c.insert(.maskCommand) }
        if flags.contains(.option)  { c.insert(.maskAlternate) }
        if flags.contains(.control) { c.insert(.maskControl) }
        if flags.contains(.shift)   { c.insert(.maskShift) }
        return c
    }

    /// e.g. "⌥⌘→", "⌘C", "F5".
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    /// Static, layout-independent name for a virtual keycode. Deliberately avoids
    /// the TextInputSource (TIS) APIs — those assert the *main* thread, and this is
    /// read from a background logging queue too, which would trap.
    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"; case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"; case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"; case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."; case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"; case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"; case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"; case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"; case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"; case kVK_F20: return "F20"
        default: return "key\(code)"
        }
    }
}
