import Foundation
import IOKit
import IOKit.ps

/// Reads battery state from two read-only IOKit sources (no privilege, no prompt):
///
///  • `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription` — live charge,
///    charging/AC state, and the time-to-empty/full estimate.
///  • The `AppleSmartBattery` IORegistry node — health (cycle count, condition,
///    design/max capacity, temperature).
///
/// Both vary by Mac model, so every field is treated as optional. A desktop Mac
/// has neither a power source of type "InternalBattery" nor an AppleSmartBattery
/// node → `BatteryInfo.isPresent == false`.
enum BatteryReader {

    private static let log = FileLog("BatteryReader")

    static func read() -> BatteryInfo {
        var info = BatteryInfo()
        info.power = readPowerSource(into: &info)
        readSmartBattery(into: &info)
        return info
    }

    // MARK: - IOPowerSources (live charge / charging / time estimate)

    private static func readPowerSource(into info: inout BatteryInfo) -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            log.warn("IOPSCopyPowerSourcesInfo/List returned nothing")
            return nil
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }

            // Only consider internal batteries (skip UPS, etc.).
            let type = desc[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }
            info.isPresent = true

            let cur = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int
            let percent: Int? = {
                guard let cur, let max, max > 0 else { return cur }
                return Int((Double(cur) / Double(max) * 100).rounded())
            }()

            let stateRaw = desc[kIOPSPowerSourceStateKey] as? String
            let isAC = (stateRaw == kIOPSACPowerValue)
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let isCharged = (desc[kIOPSIsChargedKey] as? Bool) ?? false

            // Time estimate: -1 means "still calculating", 0 means "n/a" here.
            let minutes: Int? = {
                let key = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                guard let t = desc[key] as? Int, t > 0 else { return nil }
                return t
            }()

            return PowerState(
                source: isAC ? .ac : .battery,
                isCharging: isCharging,
                isCharged: isCharged,
                chargePercent: percent,
                minutesRemaining: minutes)
        }
        return nil
    }

    // MARK: - AppleSmartBattery (health)

    private static func readSmartBattery(into info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any]
        else {
            log.warn("IORegistryEntryCreateCFProperties(AppleSmartBattery) failed")
            return
        }
        info.isPresent = true

        info.cycleCount = props["CycleCount"] as? Int

        // Design capacity, and the current full-charge capacity. Newer Macs use
        // "AppleRawMaxCapacity"/"NominalChargeCapacity"; older ones "MaxCapacity".
        info.designCapacity = props["DesignCapacity"] as? Int
        let maxCap = (props["AppleRawMaxCapacity"] as? Int)
            ?? (props["NominalChargeCapacity"] as? Int)
            ?? (props["MaxCapacity"] as? Int)
        info.maxCapacity = maxCap
        if let design = info.designCapacity, design > 0, let maxCap, maxCap > 0 {
            info.maxCapacityPercent = Int((Double(maxCap) / Double(design) * 100).rounded())
        }

        // Condition: prefer the textual "BatteryHealthCondition"/"BatteryHealth";
        // fall back to "PermanentFailureStatus" (non-zero = failure).
        info.condition = readCondition(props)

        // Temperature is reported in centi-kelvin on most Macs (e.g. 30150 → 28.5 °C).
        if let raw = props["Temperature"] as? Int, raw > 0 {
            info.temperatureCelsius = Double(raw) / 100.0 - 273.15
        }
    }

    private static func readCondition(_ props: [String: Any]) -> BatteryCondition? {
        if let s = (props["BatteryHealthCondition"] as? String) ?? (props["BatteryHealth"] as? String),
           !s.isEmpty {
            switch s {
            case "Good", "Normal":      return .normal
            case "Fair", "Poor", "Check Battery", "Service Battery", "ServiceRecommended":
                return .serviceRecommended
            default:                     return .unknown(s)
            }
        }
        if let fail = props["PermanentFailureStatus"] as? Int {
            return fail == 0 ? .normal : .serviceRecommended
        }
        return nil
    }
}
