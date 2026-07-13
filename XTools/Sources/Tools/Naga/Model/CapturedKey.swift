import Foundation

/// One captured side-button press: the modifier usages held plus the main key.
struct CapturedKey: Identifiable {
    let id = UUID()
    let modifiers: [UInt32]   // HID keyboard usages 0xE0–0xE7, sorted
    let keyUsage: UInt32
    let time: Date

    /// Mac-style combo, e.g. "⌃W", "⌥→", "⌃Page Up".
    var display: String {
        modifiers.map(HIDKeyName.modifierSymbol).joined() + HIDKeyName.name(keyUsage)
    }

    /// Verbose form with raw HID usages, e.g. "Ctrl+W · HID 224+26".
    var detail: String {
        let names = (modifiers + [keyUsage]).map(HIDKeyName.name).joined(separator: "+")
        let raw = (modifiers + [keyUsage]).map(String.init).joined(separator: "+")
        return "\(names) · HID \(raw)"
    }
}
