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

    /// Human name for a virtual keycode (best-effort; falls back to the raw code).
    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default:
            // Letters / digits / punctuation resolve via the current layout.
            if let s = Shortcut.character(for: code) { return s.uppercased() }
            return "key\(code)"
        }
    }

    /// The character a keycode produces in the current keyboard layout, if any.
    private static func character(for keyCode: UInt16) -> String? {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
