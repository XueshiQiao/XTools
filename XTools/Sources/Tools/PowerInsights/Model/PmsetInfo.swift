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

    // pmset reports these as 0/1 booleans, not minute counts.
    private static let booleanKeys: Set<String> = [
        "disablesleep", "powernap", "lowpowermode", "standby",
        "ttyskeepawake", "tcpkeepalive", "womp", "networkoversleep", "gpuswitch",
        "Sleep On Power Button", "acwake", "lidwake", "halfdim",
    ]
    // These are sleep timers in MINUTES (0 = never).
    private static let minuteKeys: Set<String> = ["displaysleep", "sleep", "disksleep"]

    /// Value formatted for humans: booleans → On/Off, timers → "N min"/"Never",
    /// `hibernatemode` → its labeled meaning, everything else → the raw value.
    var displayValue: String {
        if Self.booleanKeys.contains(key) {
            if value == "1" { return L("power.value.on") }
            if value == "0" { return L("power.value.off") }
            return value
        }
        if Self.minuteKeys.contains(key), let n = Int(value) {
            return n == 0 ? L("power.value.never") : String(format: L("power.value.minutes"), n)
        }
        if key == "hibernatemode" {
            let meaning = L("power.hibernate.\(value)")           // e.g. power.hibernate.3
            return meaning == "power.hibernate.\(value)" ? value : "\(value) · \(meaning)"
        }
        return value
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
