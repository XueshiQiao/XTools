import SwiftUI

/// The memory-pressure level macOS exposes via
/// `kern.memorystatus_vm_pressure_level` — the same green/yellow/red signal the
/// kernel uses to decide when to compress, swap, or jetsam. Values are a bitmask
/// in the sysctl (1 = Normal, 2 = Warning, 4 = Critical); anything else is
/// treated as unknown.
enum MemoryPressureLevel {
    case normal
    case warning
    case critical
    case unknown

    init(raw: Int32) {
        switch raw {
        case 1:  self = .normal
        case 2:  self = .warning
        case 4:  self = .critical
        default: self = .unknown
        }
    }

    /// Localized label, e.g. "Normal" / "正常".
    var label: String {
        switch self {
        case .normal:   return L("mem.pressure.normal")
        case .warning:  return L("mem.pressure.warning")
        case .critical: return L("mem.pressure.critical")
        case .unknown:  return L("mem.value.unknown")
        }
    }

    /// Traffic-light color: green relaxed → yellow tight → red critical.
    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .yellow
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
}

/// One current-breakdown row: a localized label, a byte value, and a short
/// plain-language subtitle explaining what it means. `symbol`/`color` drive the
/// leading icon tile so each row reads like the rest of the app.
struct MemoryRow: Identifiable {
    let id: String
    let label: String
    let subtitle: String
    let bytes: UInt64
    let symbol: String
    let color: Color
}

/// One slice of the "Memory Composition" stacked bar — a partition of total
/// physical RAM into Wired / App / Compressed / Cached / Other / Free. These
/// sum to ≈ total RAM, so each slice's width is `bytes / totalRAM`. `id` doubles
/// as the localization key suffix (`mem.cat.<id>`).
struct MemoryCategory: Identifiable {
    let id: String          // "wired", "app", "compressed", "cached", "other", "free"
    let labelKey: String    // localized label key, e.g. "mem.cat.wired"
    let bytes: UInt64
    let color: Color
}

extension Color {
    /// Builds a Color from a 6-digit hex string (`"#6366f1"` or `"6366f1"`),
    /// used for the fixed composition palette. Falls back to gray on a malformed
    /// string so a typo can't crash the bar.
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&rgb) else {
            self = .gray
            return
        }
        self.init(.sRGB,
                  red:   Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >>  8) & 0xFF) / 255,
                  blue:  Double( rgb        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// One cumulative since-boot counter (pageins, swapouts, …). These are monotonic
/// totals, NOT current state, so they're shown as plain counts in a collapsed
/// disclosure to avoid alarming the user with the big digit counts.
struct MemoryCounter: Identifiable {
    let id: String
    let label: String
    let count: UInt64
}

/// A full snapshot of everything the Memory tool reads in one refresh: the
/// headline pressure signal, the current breakdown rows, the swap "used of
/// total", and the since-boot counters. Built off the main thread, published on
/// main.
struct MemorySnapshot {
    var pressure: MemoryPressureLevel = .unknown
    var freePercent: Int?                 // "System-wide memory free percentage"
    var totalRAM: UInt64 = 0              // hw.memsize

    // Composition: a partition of total RAM into Wired/App/Compressed/Cached/
    // Other/Free, in display order. Drives the stacked bar + legend.
    var categories: [MemoryCategory] = []
    var compressedPhysical: UInt64 = 0   // bytes the compressor actually occupies
    var compressedLogical: UInt64 = 0    // logical bytes those compressed pages hold

    var rows: [MemoryRow] = []           // Free / Active / Inactive / Wired / …
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var counters: [MemoryCounter] = []   // since-boot totals

    // Valid only when both sources came through: total RAM (sysctl) AND at least
    // one non-zero breakdown row (memory_pressure). Otherwise the breakdown would
    // render as a wall of "0 bytes" and we should show the placeholder instead.
    var isValid: Bool { totalRAM > 0 && rows.contains { $0.bytes > 0 } }

    // The composition bar needs total RAM plus at least one non-zero category.
    var hasComposition: Bool { totalRAM > 0 && categories.contains { $0.bytes > 0 } }

    // Show the "physical holds logical" savings line only when the compressor is
    // actually holding more logical data than it physically occupies.
    var hasCompressionSavings: Bool { compressedLogical > compressedPhysical && compressedPhysical > 0 }
}
