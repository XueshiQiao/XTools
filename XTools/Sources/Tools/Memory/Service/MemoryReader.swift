import Foundation
import Darwin

/// Reads system memory state from two read-only sources (no sudo, no prompt):
///
///  • `/usr/bin/memory_pressure` (one-shot) — parsed for the "Label: number"
///    page counts and the headline "System-wide memory free percentage: N%".
///    Each page count is multiplied by the page size to get bytes.
///  • `sysctl` (`sysctlbyname`) — `hw.memsize` (total RAM), `hw.pagesize`
///    (page size, 16384 on Apple Silicon), `kern.memorystatus_vm_pressure_level`
///    (the green/yellow/red signal), and `vm.swapusage` (swap used/total).
///
/// All of these are unprivileged, so the tool never triggers a password prompt.
enum MemoryReader {

    private static let log = FileLog("MemoryReader")
    private static let memoryPressurePath = "/usr/bin/memory_pressure"

    static func read() -> MemorySnapshot {
        var snap = MemorySnapshot()

        // hw.pagesize is a 4-byte int in Darwin (use the 32-bit reader, not the
        // 64-bit one, so the kernel fills the whole buffer on every arch).
        let pageSize = UInt64(sysctlInt32("hw.pagesize") ?? 16384)
        snap.totalRAM = sysctlUInt64("hw.memsize") ?? 0
        snap.pressure = MemoryPressureLevel(raw: sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 0)

        // Swap: used/total bytes from the typed struct in Darwin.
        let swap = readSwapUsage()
        snap.swapUsed = swap.used
        snap.swapTotal = swap.total

        // memory_pressure → page counts + headline free %.
        let pages = parseMemoryPressure()
        snap.freePercent = pages.freePercent

        func bytes(_ key: String) -> UInt64 { (pages.counts[key] ?? 0) * pageSize }

        // Current breakdown rows (issue-specified order + icons).
        snap.rows = [
            MemoryRow(id: "free",
                      label: L("mem.row.free"), subtitle: L("mem.row.free.sub"),
                      bytes: bytes("Pages free"), symbol: "circle.dashed", color: .green),
            MemoryRow(id: "active",
                      label: L("mem.row.active"), subtitle: L("mem.row.active.sub"),
                      bytes: bytes("Pages active"), symbol: "bolt.fill", color: .blue),
            MemoryRow(id: "inactive",
                      label: L("mem.row.inactive"), subtitle: L("mem.row.inactive.sub"),
                      bytes: bytes("Pages inactive"), symbol: "pause.circle.fill", color: .teal),
            MemoryRow(id: "wired",
                      label: L("mem.row.wired"), subtitle: L("mem.row.wired.sub"),
                      bytes: bytes("Pages wired down"), symbol: "lock.fill", color: .indigo),
            MemoryRow(id: "compressed",
                      label: L("mem.row.compressed"), subtitle: L("mem.row.compressed.sub"),
                      bytes: bytes("Pages used by compressor"), symbol: "archivebox.fill", color: .purple),
            MemoryRow(id: "purgeable",
                      label: L("mem.row.purgeable"), subtitle: L("mem.row.purgeable.sub"),
                      bytes: bytes("Pages purgeable"), symbol: "trash.fill", color: .orange),
        ]

        // Cumulative since-boot counters (raw counts, not bytes).
        func count(_ key: String) -> UInt64 { pages.counts[key] ?? 0 }
        snap.counters = [
            MemoryCounter(id: "pageins",       label: L("mem.counter.pageins"),       count: count("Pageins")),
            MemoryCounter(id: "pageouts",      label: L("mem.counter.pageouts"),      count: count("Pageouts")),
            MemoryCounter(id: "swapins",       label: L("mem.counter.swapins"),       count: count("Swapins")),
            MemoryCounter(id: "swapouts",      label: L("mem.counter.swapouts"),      count: count("Swapouts")),
            MemoryCounter(id: "compressions",  label: L("mem.counter.compressions"),  count: count("Pages compressed")),
            MemoryCounter(id: "decompressions",label: L("mem.counter.decompressions"),count: count("Pages decompressed")),
            MemoryCounter(id: "purged",        label: L("mem.counter.purged"),        count: count("Pages purged")),
            MemoryCounter(id: "throttled",     label: L("mem.counter.throttled"),     count: count("Pages throttled")),
        ]

        return snap
    }

    // MARK: - memory_pressure parsing

    /// Parsed `memory_pressure` output: each "Label: number" line keyed by its
    /// exact prefix (the part before the colon), plus the headline free %.
    private struct ParsedPressure {
        var counts: [String: UInt64] = [:]
        var freePercent: Int?
    }

    /// Exact label prefixes we recognise (everything before the colon). Anything
    /// else (section headers, the "The system has …" preamble) is ignored.
    private static let knownLabels: Set<String> = [
        "Pages free", "Pages purgeable", "Pages purged", "Swapins", "Swapouts",
        "Pages active", "Pages inactive", "Pages speculative", "Pages throttled",
        "Pages wired down", "Pages used by compressor", "Pages decompressed",
        "Pages compressed", "Pageins", "Pageouts",
    ]

    private static func parseMemoryPressure() -> ParsedPressure {
        var parsed = ParsedPressure()
        guard let out = runMemoryPressure() else { return parsed }

        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if label == "System-wide memory free percentage" {
                // "53%" → 53
                let digits = rest.prefix { $0.isNumber }
                parsed.freePercent = Int(digits)
                continue
            }
            guard knownLabels.contains(label) else { continue }
            // The value is the leading run of digits (line may have a trailing space).
            let digits = rest.prefix { $0.isNumber }
            if let n = UInt64(digits) { parsed.counts[label] = n }
        }
        return parsed
    }

    private static func runMemoryPressure() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: memoryPressurePath)
        // No args → one-shot snapshot (no continuous monitoring).
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // swallow stderr
        do {
            try proc.run()
        } catch {
            log.error("failed to run memory_pressure: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - sysctl helpers

    /// `vm.swapusage` → the typed `xsw_usage` struct (bytes). Declared in Darwin.
    private static func readSwapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            log.warn("sysctl vm.swapusage failed")
            return (0, 0)
        }
        return (UInt64(usage.xsu_used), UInt64(usage.xsu_total))
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
