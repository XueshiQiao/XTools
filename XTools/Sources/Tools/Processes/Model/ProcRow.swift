import Foundation
import Darwin

/// Which memory metric the rows currently carry. The two are NOT interchangeable
/// — they are different Activity Monitor columns and can differ by ~10x on the
/// same process (WindowServer, measured: footprint 5.8G vs resident 624M, the gap
/// being compressed pages; logd is the reverse, because resident counts clean
/// file-backed pages that footprint excludes). So the column HEADER must follow
/// the metric, never silently mix the two.
enum MemoryMetric {
    /// `phys_footprint` — Activity Monitor's "Memory" column. Only obtainable for
    /// other users' processes by way of the setuid `top`, hence `.top` mode.
    case footprint
    /// `resident_size` — Activity Monitor's "Real Mem" column, i.e. `ps -o rss`.
    /// What the fallback (`ps`) mode can offer.
    case resident
}

/// Identity of a process INSTANCE, not just a slot in the pid table.
///
/// pids get recycled. `pid` alone would let a dead process's row silently become
/// a live unrelated process (wrong metrics at best, a wrong kill at worst), so the
/// row identity carries the start time as well — the pair is unique for the life
/// of the machine.
struct ProcID: Hashable {
    let pid: pid_t
    /// Microseconds since epoch. 0 for `kernel_task`, which has no bsdinfo.
    let startTime: UInt64
}

/// One row of the process list: an immutable value snapshot.
///
/// Deliberately a value type + `Equatable`: the list re-renders every refresh, and
/// SwiftUI must be able to tell "this row did not change" cheaply, or 800 rows
/// become 800 removals + 800 inserts every tick.
struct ProcRow: Identifiable, Equatable {

    // MARK: Identity (from the in-process sysctl roster — cheap, works for ALL uids)

    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    /// Symlink-resolved real path. nil for `kernel_task` and for the handful of
    /// processes that exit mid-scan.
    let executablePath: String?
    let startTime: UInt64
    /// Executable's last path component, or a `pid N` placeholder.
    let name: String
    /// Apple-shipped system component (path under /System, /usr/libexec, … or a
    /// `com.apple.*` bundle id). Drives the "hide system processes" filter.
    let isAppleSystem: Bool

    // MARK: Metrics (from `top`, or from `ps` in fallback mode)
    //
    // All optional: a pid that appeared in the roster but not yet in a metrics
    // sample has no numbers YET. That must render as "—", never as 0 — a fake 0%
    // is a lie the user cannot distinguish from a genuinely idle process.

    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var threadCount: Int?

    var id: ProcID { ProcID(pid: pid, startTime: startTime) }

    // MARK: Sort keys
    //
    // `Optional` is not `Comparable`, and a `Table` column needs a Comparable key
    // path, so the optional metrics get non-optional sort projections. A process
    // whose metrics have not arrived yet sorts BELOW every real value rather than
    // masquerading as 0 — "unknown" is not "idle".

    var cpuSort: Double { cpuPercent ?? -1 }
    var memorySort: UInt64 { memoryBytes ?? 0 }
    var threadSort: Int { threadCount ?? -1 }

    // MARK: Derived

    var runsAsRoot: Bool { uid == 0 }
    var isCurrentUser: Bool { uid == getuid() }

    /// `kernel_task`. It is not a real BSD process: no path, no argv, unkillable.
    /// It only exists in this list because it is the single most-asked-about
    /// process on macOS ("why is kernel_task at 300%?") and the whole point of
    /// this tool is to answer that question.
    var isKernelTask: Bool { pid == 0 }

    /// `launchd`. Killing pid 1 panics the machine.
    var isLaunchd: Bool { pid == 1 }

    /// Whether Quit / Force Quit may be offered at all. pid 0 and pid 1 are
    /// structurally unkillable; every other process is *offered* (the action layer
    /// still re-verifies the instance fingerprint before it signals anything).
    var canTerminate: Bool { pid > 1 }

    /// The `.app` bundle this executable lives inside — the OUTERMOST one, so a
    /// deeply-nested `Google Chrome Helper.app` resolves to `/Applications/Google
    /// Chrome.app` (what the user thinks of as "the app"), not to the inner helper
    /// bundle. The FIRST path component ending in `.app` is the outermost one.
    /// Same rule as `NowPlayingScanner.appBundlePath(forExecutable:)`.
    var owningAppBundlePath: String? {
        guard let p = executablePath else { return nil }
        let comps = p.components(separatedBy: "/")
        guard let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let joined = comps[0...idx].joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }
}
