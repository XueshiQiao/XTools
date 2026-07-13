import Foundation

/// Human-readable names for HID Keyboard/Keypad usages (usage page 0x07).
/// Used by the live input monitor and (later) the calibration UI.
enum HIDKeyName {

    static func isModifier(_ usage: UInt32) -> Bool { usage >= 0xE0 && usage <= 0xE7 }

    /// Modifier as a Mac symbol: ⌃ ⇧ ⌥ ⌘.
    static func modifierSymbol(_ usage: UInt32) -> String {
        switch usage {
        case 0xE0, 0xE4: return "⌃" // L/R Control
        case 0xE1, 0xE5: return "⇧" // L/R Shift
        case 0xE2, 0xE6: return "⌥" // L/R Alt/Option
        case 0xE3, 0xE7: return "⌘" // L/R GUI/Command
        default: return "?"
        }
    }

    static func name(_ usage: UInt32) -> String {
        switch usage {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(0x41 + (usage - 0x04)))) // A–Z
        case 0x1E...0x26: return String(usage - 0x1D)                                // 1–9
        case 0x27: return "0"
        case 0x28: return "↩"
        case 0x29: return "Esc"
        case 0x2A: return "⌫"
        case 0x2B: return "⇥"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x31: return "\\"
        case 0x33: return ";"
        case 0x34: return "'"
        case 0x35: return "`"
        case 0x36: return ","
        case 0x37: return "."
        case 0x38: return "/"
        case 0x3A...0x45: return "F\(usage - 0x39)"        // F1–F12
        case 0x68...0x73: return "F\(usage - 0x68 + 13)"   // F13–F24
        case 0x49: return "Ins"
        case 0x4A: return "Home"
        case 0x4B: return "Page Up"
        case 0x4C: return "⌦"
        case 0x4D: return "End"
        case 0x4E: return "Page Down"
        case 0x4F: return "→"
        case 0x50: return "←"
        case 0x51: return "↓"
        case 0x52: return "↑"
        case 0xE0: return "LCtrl"
        case 0xE1: return "LShift"
        case 0xE2: return "LAlt"
        case 0xE3: return "LCmd"
        case 0xE4: return "RCtrl"
        case 0xE5: return "RShift"
        case 0xE6: return "RAlt"
        case 0xE7: return "RCmd"
        default: return "usage \(usage)"
        }
    }
}
