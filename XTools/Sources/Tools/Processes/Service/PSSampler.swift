import Foundation
import Darwin

/// One process's metrics, from whichever source produced them.
struct ProcMetrics: Equatable {
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var threadCount: Int?
}

/// Metrics via `/bin/ps`. Two jobs, one implementation:
///
/// 1. **The first-paint CPU seed.** `top`'s first sample block reports 0.0% for
///    every process (it has no delta baseline yet — measured: a process burning
///    100% CPU for 3s shows 0.0 / 66.6 / 98.7 across blocks 1/2/3). Without a seed
///    the CPU column would sit blank for a whole refresh interval after the tool
///    opens. `ps`'s `pcpu` is the kernel's own decayed average and is usable
///    immediately, so one 30ms call at open fills the column instantly.
///
/// 2. **The fallback (`ps`) mode.** If `top` cannot be parsed at all (a future
///    macOS changes its output), the tool degrades to polling this instead of
///    blank-screening. The cost is the memory metric: `ps` has no footprint field
///    — it only offers `rss` — so in this mode the column is relabelled to
///    "Real Mem", which is what it honestly is.
///
/// Why `ps` sees root processes at all: `/bin/ps` is setuid root
/// (`-rwsr-xr-x`), so it reads what our own libproc calls cannot. No password, no
/// entitlement, no privileged helper. This only works because XTools is not
/// sandboxed — the App Sandbox forbids exec of setuid binaries outright.
enum PSSampler {

    private static let log = FileLog("Processes")

    /// A full sweep. ~30ms for ~800 processes (measured). Call OFF the main thread.
    /// Returns an empty dictionary on failure — callers keep their previous sample
    /// rather than flashing "—" across every row.
    static func sample() -> [pid_t: ProcMetrics] {
        // All-numeric columns only. `comm`/`args` would introduce spaces and
        // truncation into the output and break whitespace splitting, and we do not
        // need them — identity comes from the roster.
        guard let out = run("/bin/ps", ["-axo", "pid=,pcpu=,rss="]) else { return [:] }

        var result: [pid_t: ProcMetrics] = [:]
        result.reserveCapacity(900)
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3,
                  let pid = pid_t(f[0]),
                  let cpu = Double(f[1]),          // POSIX parse; never NumberFormatter
                  let rssKB = UInt64(f[2]) else { continue }
            result[pid] = ProcMetrics(cpuPercent: cpu,
                                      memoryBytes: rssKB * 1024,
                                      threadCount: nil)   // ps has no thread count on macOS
        }
        return result
    }

    /// Run a tool with a POSIX locale and return stdout, or nil on any failure.
    ///
    /// `LC_ALL=C` is pinned even though macOS 26's `ps`/`top` were measured to
    /// ignore locale entirely (identical output under zh_CN and de_DE): the older
    /// systems this app supports are unverified, a decimal comma would silently
    /// break every `Double(...)` parse, and the line costs nothing.
    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LC_NUMERIC"] = "C"
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            log.error("failed to launch \(launchPath): \(error.localizedDescription)")
            return nil
        }
        // Read BEFORE waiting: a child that fills the 64KB pipe buffer blocks in
        // write() forever if we wait first, and ~800 rows is comfortably past that.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        // Drain stderr too, for the same reason.
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            log.error("\(launchPath) exited \(task.terminationStatus)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
