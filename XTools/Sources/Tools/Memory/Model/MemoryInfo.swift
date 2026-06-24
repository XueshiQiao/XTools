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

    var rows: [MemoryRow] = []           // Free / Active / Inactive / Wired / …
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var counters: [MemoryCounter] = []   // since-boot totals

    // Valid only when both sources came through: total RAM (sysctl) AND at least
    // one non-zero breakdown row (memory_pressure). Otherwise the breakdown would
    // render as a wall of "0 bytes" and we should show the placeholder instead.
    var isValid: Bool { totalRAM > 0 && rows.contains { $0.bytes > 0 } }
}
