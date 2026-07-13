import Foundation

/// One side button's mapping: the sentinel key it emits (F13–F18) → the shortcut
/// we emit instead. `index` is the physical button number (1…6).
struct ButtonMapping: Codable, Identifiable {
    let index: Int
    let sentinelUsage: UInt32   // HID keyboard usage the button emits (F13=104 … F18=109)
    var target: Shortcut?
    var enabled: Bool

    var id: Int { index }

    /// Display name of the sentinel, e.g. "F13".
    var sentinelName: String { HIDKeyName.name(sentinelUsage) }

    /// The 6-button default: button i emits F(12+i) → usage 103+i (F13=104…F18=109).
    static let defaults: [ButtonMapping] = (1...6).map {
        ButtonMapping(index: $0, sentinelUsage: UInt32(103 + $0), target: nil, enabled: true)
    }
}
