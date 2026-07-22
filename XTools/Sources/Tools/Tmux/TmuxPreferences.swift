import Foundation
import AppKit
import Carbon.HIToolbox

/// UserDefaults-backed prefs for the Tmux palette hotkey and window frame.
/// Kept inside `Tools/Tmux/` so the tool stays self-contained.
enum TmuxPreferences {

    private static let enabledKey = "tmux.palette.hotkey.enabled"
    private static let hotKeyKey = "tmux.palette.hotkey.combo"
    private static let frameKey = "tmux.palette.window.frame"

    /// Default: ⌃⌥⌘T — unlikely to collide with terminal / IDE bindings.
    static let defaultHotKey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_T),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Default ON — the hotkey is the main reason the palette exists.
    static var hotkeyEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var hotKey: KeyCombo {
        get {
            guard let raw = UserDefaults.standard.string(forKey: hotKeyKey),
                  let data = raw.data(using: .utf8),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
            else { return defaultHotKey }
            return combo
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let raw = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(raw, forKey: hotKeyKey)
            }
        }
    }

    /// Last palette window frame in screen coordinates, if the user resized/moved it.
    static var windowFrame: NSRect? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: frameKey) else { return nil }
            let r = NSRectFromString(raw)
            return r.width > 80 && r.height > 80 ? r : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSStringFromRect(newValue), forKey: frameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: frameKey)
            }
        }
    }
}
