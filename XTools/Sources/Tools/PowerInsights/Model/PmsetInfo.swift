import Foundation

/// One parsed `pmset -g` setting (e.g. `displaysleep = 10`). `key` is the raw
/// pmset token (stable, used to look up a localized label); `value` is shown
/// verbatim.
struct PmsetSetting: Identifiable, Hashable {
    let key: String
    let value: String
    var id: String { key }

    /// A friendly localized label for the well-known keys, falling back to the
    /// raw pmset token for anything we don't have a translation for.
    var label: String {
        let mapped = L("power.setting.\(key)")
        return mapped == "power.setting.\(key)" ? key : mapped
    }
}

/// A single Sleep/Wake event parsed from `pmset -g log`.
struct WakeEvent: Identifiable, Hashable {
    enum Kind { case wake, sleep, darkWake }

    let id = UUID()
    let kind: Kind
    let date: Date?
    let reason: String      // the human reason pmset printed (may be empty)

    /// SF Symbol for the row icon.
    var symbol: String {
        switch kind {
        case .wake:     return "sun.max.fill"
        case .sleep:    return "moon.fill"
        case .darkWake: return "moon.stars.fill"
        }
    }
}
