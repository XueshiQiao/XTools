import Foundation

/// Models representing the decoded JSON output of `ccusage daily --json --by-agent`
/// and convenience aggregations for the UI.
struct CCUsageReport: Codable, Equatable {
    var daily: [CCDailyEntry]
    var totals: CCTotals

    static let empty = CCUsageReport(daily: [], totals: .empty)

    /// Returns the entry matching `todayString` (YYYY-MM-DD), if present.
    func entry(for dateString: String) -> CCDailyEntry? {
        daily.first { $0.period == dateString }
    }

    /// Today's entry using the local calendar date, or nil if no usage today yet.
    func todayEntry(now: Date = Date(), calendar: Calendar = .current) -> CCDailyEntry? {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: now)
        return entry(for: key)
    }

    /// Yesterday's entry using the local calendar date.
    func yesterdayEntry(now: Date = Date(), calendar: Calendar = .current) -> CCDailyEntry? {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: yesterday)
        return entry(for: key)
    }

    ///Daily entries sorted newest-first for history tables.
    var dailyNewestFirst: [CCDailyEntry] {
        daily.sorted { $0.period > $1.period }
    }

    /// Last `n` days of entries in chronological order (oldest → newest),
    /// filling missing calendar days with zero-usage entries so bar charts
    /// have a continuous x-axis.
    func recentDays(count: Int, now: Date = Date(), calendar: Calendar = .current) -> [CCDailyEntry] {
        guard count > 0 else { return [] }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let byPeriod = Dictionary(uniqueKeysWithValues: daily.map { ($0.period, $0) })
        var result: [CCDailyEntry] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = fmt.string(from: date)
            if let existing = byPeriod[key] {
                result.append(existing)
            } else {
                result.append(CCDailyEntry.zero(period: key))
            }
        }
        return result
    }
}

struct CCDailyEntry: Codable, Equatable, Identifiable {
    var period: String
    var agent: String?
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var totalTokens: Int64
    var totalCost: Double
    var modelsUsed: [String]?
    var modelBreakdowns: [CCModelBreakdown]?
    var agents: [CCAgentBreakdown]?

    var id: String { period }

    static func zero(period: String) -> CCDailyEntry {
        CCDailyEntry(
            period: period,
            agent: "all",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 0,
            totalCost: 0,
            modelsUsed: [],
            modelBreakdowns: [],
            agents: []
        )
    }

    /// Short MM-DD label for compact charts.
    var shortDateLabel: String {
        if period.count == 10 {
            return String(period.suffix(5))
        }
        return period
    }

    /// Sorted agent breakdowns by cost descending (then tokens descending).
    var sortedAgents: [CCAgentBreakdown] {
        (agents ?? []).sorted {
            if abs($0.totalCost - $1.totalCost) > 0.0001 {
                return $0.totalCost > $1.totalCost
            }
            return $0.totalTokens > $1.totalTokens
        }
    }

    /// Sorted model breakdowns by cost descending (then tokens descending).
    var sortedModels: [CCModelBreakdown] {
        (modelBreakdowns ?? []).sorted {
            if abs($0.cost - $1.cost) > 0.0001 {
                return $0.cost > $1.cost
            }
            return $0.totalTokens > $1.totalTokens
        }
    }
}

struct CCAgentBreakdown: Codable, Equatable, Identifiable {
    var agent: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var totalTokens: Int64
    var totalCost: Double
    var modelsUsed: [String]?
    var modelBreakdowns: [CCModelBreakdown]?

    var id: String { agent }

    var displayName: String {
        switch agent.lowercased() {
        case "claude":      return "Claude"
        case "codex":       return "Codex"
        case "antigravity": return "Antigravity"
        case "grok":        return "Grok"
        case "cursor":      return "Cursor"
        case "gemini":      return "Gemini"
        default:            return agent.capitalized
        }
    }
}

struct CCModelBreakdown: Codable, Equatable, Identifiable {
    var modelName: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var cost: Double
    var missingPricing: Bool?

    var id: String { modelName }

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

struct CCTotals: Codable, Equatable {
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheCreationTokens: Int64
    var cacheReadTokens: Int64
    var totalTokens: Int64
    var totalCost: Double
    var unpricedModels: [String]?

    static let empty = CCTotals(
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        totalTokens: 0,
        totalTokensCost: 0
    )

    init(
        inputTokens: Int64,
        outputTokens: Int64,
        cacheCreationTokens: Int64,
        cacheReadTokens: Int64,
        totalTokens: Int64,
        totalTokensCost: Double,
        unpricedModels: [String]? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalTokensCost
        self.unpricedModels = unpricedModels
    }
}

// MARK: - Formatting helpers

enum CCFormat {
    static func cost(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "$%.2f", value)
        } else if value >= 0.01 || value == 0 {
            return String(format: "$%.2f", value)
        } else {
            return String(format: "$%.4f", value)
        }
    }

    /// Compact token count (e.g. `393.1M`, `1.86B`, `42.5K`, `850`).
    static func compactTokens(_ count: Int64) -> String {
        let absVal = Double(abs(count))
        let sign = count < 0 ? "-" : ""
        if absVal >= 1_000_000_000 {
            return String(format: "%@%.2fB", sign, absVal / 1_000_000_000)
        } else if absVal >= 1_000_000 {
            return String(format: "%@%.1fM", sign, absVal / 1_000_000)
        } else if absVal >= 1_000 {
            return String(format: "%@%.1fK", sign, absVal / 1_000)
        } else {
            return "\(count)"
        }
    }

    /// Full comma-separated token count (e.g. `393,130,163`).
    static func fullTokens(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
