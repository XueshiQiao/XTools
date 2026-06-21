import Foundation

/// Battery condition as reported by the SMC / IORegistry (`BatteryHealth` /
/// `PermanentFailureStatus`), mapped to the user-facing wording macOS uses.
enum BatteryCondition {
    case normal
    case serviceRecommended
    case unknown(String)

    /// Localized label, e.g. "Normal" / "正常".
    var label: String {
        switch self {
        case .normal:             return L("power.condition.normal")
        case .serviceRecommended: return L("power.condition.service")
        case .unknown(let raw):   return raw.isEmpty ? L("power.value.unknown") : raw
        }
    }

    /// Whether this condition should read as healthy (green) vs. needs-attention.
    var isHealthy: Bool {
        if case .normal = self { return true }
        return false
    }
}

/// Whether the Mac is currently running on battery or external (AC) power, and —
/// when known — how it's progressing toward empty/full.
struct PowerState {
    enum Source { case battery, ac, unknown }

    let source: Source
    let isCharging: Bool
    let isCharged: Bool          // plugged in and at 100%
    let chargePercent: Int?      // 0...100 (current charge)
    /// Minutes until empty (on battery) or full (charging). nil while macOS is
    /// still calculating ("estimating") or when it doesn't apply.
    let minutesRemaining: Int?
}

/// A snapshot of everything the Power tool knows about the battery. Every field
/// is optional because the available keys differ across Mac models, and a
/// desktop Mac has no battery at all (`isPresent == false`).
struct BatteryInfo {
    var isPresent: Bool = false

    // From IOPowerSources (live charge / charging / time estimate).
    var power: PowerState?

    // From the AppleSmartBattery IORegistry node (health).
    var cycleCount: Int?
    var condition: BatteryCondition?
    var maxCapacityPercent: Int?     // "battery health" — max vs. design capacity
    var designCapacity: Int?         // mAh
    var maxCapacity: Int?            // mAh (current full-charge capacity)
    var temperatureCelsius: Double?  // °C, if the SMC exposes it
}
