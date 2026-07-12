import Foundation
import Darwin

/// BSD process state (`p_stat`). The values are the classic `SIDL`/`SRUN`/…
/// constants from `<sys/proc.h>`.
enum ProcessState: Hashable {
    case idle
    case running
    case sleeping
    case stopped
    case zombie
    case unknown

    init(rawStat: Int32) {
        switch rawStat {
        case 1:  self = .idle       // SIDL   — being created
        case 2:  self = .running    // SRUN
        case 3:  self = .sleeping   // SSLEEP
        case 4:  self = .stopped    // SSTOP
        case 5:  self = .zombie     // SZOMB  — dead, awaiting its parent's wait()
        default: self = .unknown
        }
    }
}

/// A running process as seen by the Launch Manager.
///
/// `executablePath` is resolved via `proc_pidpath`, which needs no privilege and
/// resolves root-owned processes too (measured: 134/140 root pids on macOS 26).
/// A nil path means the process exited mid-scan, not that it belongs to root.
struct ManagedProcess: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let executablePath: String?

    /// BSD process state, straight from `kinfo_proc.kp_proc.p_stat`.
    ///
    /// It matters because a ZOMBIE is not a process any more: it is a dead one
    /// whose parent has not reaped it. It holds no memory, burns no CPU, has no
    /// executable path, and cannot be killed (only its parent can clear it). Any
    /// consumer that lists or signals processes has to be able to tell one apart —
    /// the field was already in the `kinfo_proc` we fetch and was simply discarded.
    var state: ProcessState = .unknown

    var id: pid_t { pid }

    /// Dead, awaiting reaping by its parent. Not signalable, not listable.
    var isZombie: Bool { state == .zombie }

    /// Runs as root → killing it needs a privileged (password-prompt) path.
    var runsAsRoot: Bool { uid == 0 }

    /// Display name: the executable's last path component, else "pid N".
    var name: String {
        if let p = executablePath, !p.isEmpty {
            return (p as NSString).lastPathComponent
        }
        return "pid \(pid)"
    }

    /// The `.app` bundle this executable lives inside, e.g.
    /// `/Applications/BaiduNetdisk_mac.app`, or nil if not inside an app bundle.
    var owningAppBundlePath: String? {
        guard let p = executablePath else { return nil }
        guard let range = p.range(of: ".app/") else { return nil }
        return String(p[p.startIndex..<range.lowerBound]) + ".app"
    }
}
