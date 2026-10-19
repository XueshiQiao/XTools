import Foundation

/// Refresh cadence for the CCUsage tool. Supports presets (5s / 10s / 30s / 60s / Manual)
/// plus a user-customizable interval in seconds.
enum CCRefreshPreset: String, CaseIterable, Identifiable {
    case sec5 = "5s"
    case sec10 = "10s"
    case sec30 = "30s"
    case sec60 = "60s"
    case custom = "custom"
    case manual = "manual"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sec5:   return L("ccusage.interval.5s")
        case .sec10:  return L("ccusage.interval.10s")
        case .sec30:  return L("ccusage.interval.30s")
        case .sec60:  return L("ccusage.interval.60s")
        case .custom: return L("ccusage.interval.custom")
        case .manual: return L("ccusage.interval.manual")
        }
    }
}

/// Number of recent days shown on the trend bar chart.
enum CCTrendRange: Int, CaseIterable, Identifiable {
    case days7 = 7
    case days14 = 14
    case days30 = 30

    var id: Int { rawValue }
    var days: Int { rawValue }

    var label: String {
        switch self {
        case .days7:  return L("ccusage.range.7d")
        case .days14: return L("ccusage.range.14d")
        case .days30: return L("ccusage.range.30d")
        }
    }
}

/// Tool-local persistence for CCUsage preferences.
final class CCUsagePreferences: ObservableObject {

    private enum Key {
        static let preset = "ccusage.refreshPreset"
        static let customSeconds = "ccusage.customRefreshSeconds"
        static let trendRange = "ccusage.trendRange"
    }

    private let defaults: UserDefaults

    @Published var preset: CCRefreshPreset {
        didSet { defaults.set(preset.rawValue, forKey: Key.preset) }
    }

    /// Custom refresh interval in seconds (clamped to 2...3600).
    @Published var customSeconds: Int {
        didSet {
            let clamped = max(2, min(3600, customSeconds))
            if clamped != customSeconds {
                customSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Key.customSeconds)
        }
    }

    @Published var trendRange: CCTrendRange {
        didSet { defaults.set(trendRange.rawValue, forKey: Key.trendRange) }
    }

    /// Effective timer interval in seconds, or `nil` when set to manual.
    var effectiveSeconds: TimeInterval? {
        switch preset {
        case .sec5:   return 5
        case .sec10:  return 10
        case .sec30:  return 30
        case .sec60:  return 60
        case .custom: return TimeInterval(max(2, min(3600, customSeconds)))
        case .manual: return nil
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawPreset = defaults.string(forKey: Key.preset) ?? ""
        self.preset = CCRefreshPreset(rawValue: rawPreset) ?? .sec5
        let savedCustom = defaults.integer(forKey: Key.customSeconds)
        self.customSeconds = savedCustom >= 2 ? min(3600, savedCustom) : 15
        let savedRange = defaults.integer(forKey: Key.trendRange)
        self.trendRange = CCTrendRange(rawValue: savedRange) ?? .days14
    }
}
