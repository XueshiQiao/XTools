import Foundation

/// One parsed `pmset -g` setting (e.g. `displaysleep = 10`). `key` is the raw
/// pmset token (stable, used to look up a localized label); `value` is shown
/// verbatim.
struct PmsetSetting: Identifiable, Hashable {
    let key: String
    let value: String
    var id: String { key }

    /// A friendly localized label for the well-known keys, falling back to the
    /// raw pmset token for anything we don't have a translation for. The key is
    /// space-stripped for the lookup so "Sleep On Power Button" maps to
    /// `power.setting.SleepOnPowerButton`.
    var label: String {
        let lookup = "power.setting.\(key.replacingOccurrences(of: " ", with: ""))"
        let mapped = L(lookup)
        return mapped == lookup ? key : mapped
    }

    // 0/1 booleans (not minute counts).
    private static let booleanKeys: Set<String> = [
        "disablesleep", "SleepDisabled", "powernap", "lowpowermode", "standby",
        "ttyskeepawake", "tcpkeepalive", "womp", "networkoversleep",
        "Sleep On Power Button", "acwake", "lidwake", "halfdim", "proximitywake",
        "autopoweroff", "ResetToDefaults",
    ]
    private static let minuteKeys: Set<String> = ["displaysleep", "sleep", "disksleep"]
    private static let secondKeys: Set<String> = ["standbydelaylow", "standbydelayhigh", "autopoweroffdelay"]
    private static let percentKeys: Set<String> = ["highstandbythreshold"]
    /// Enum settings → the L() prefix that maps a value to its meaning.
    private static let enumPrefixes: [String: String] = [
        "hibernatemode": "power.hibernate",
        "powermode": "power.powermode",
        "gpuswitch": "power.gpuswitch",
    ]

    /// Value formatted for humans, as "<text> (<raw>)" where the text replaces a
    /// bare number (booleans, enums), or with a unit otherwise. Unknown keys show
    /// the raw value verbatim.
    var displayValue: String {
        if Self.booleanKeys.contains(key) {
            if value == "1" { return L("power.value.on") }
            if value == "0" { return L("power.value.off") }
            return value
        }
        if let prefix = Self.enumPrefixes[key] {
            let meaning = L("\(prefix).\(value)")
            return meaning == "\(prefix).\(value)" ? value : "\(meaning) (\(value))"
        }
        if Self.minuteKeys.contains(key), let n = Int(value) {
            return n == 0 ? L("power.value.never") : String(format: L("power.value.minutes"), n)
        }
        if Self.secondKeys.contains(key), let n = Int(value) {
            return String(format: L("power.value.seconds"), n)
        }
        if Self.percentKeys.contains(key), Int(value) != nil {
            return "\(value)%"
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
