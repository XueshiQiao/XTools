import Foundation
import Darwin

/// Kills processes. User-owned processes are signalled directly (no privilege);
/// root-owned processes are killed through one admin password prompt.
enum ProcessReaper {

    private static let log = FileLog("ProcessReaper")

    /// Graceful then forceful reap of USER-owned processes: SIGTERM now, SIGKILL
    /// after `grace` for any that survive. Non-blocking — the SIGKILL sweep is
    /// scheduled on `queue`. Returns the pids that were signalled.
    ///
    /// Takes full `ManagedProcess` values (not bare pids) so the SIGKILL sweep can
    /// re-check each pid's executable path and SKIP it if the path no longer
    /// matches — guarding against PID recycling during the grace window (the OS
    /// could hand the freed pid to an unrelated process).
    @discardableResult
    static func reapUser(_ processes: [ManagedProcess], grace: TimeInterval = 2.0,
                         on queue: DispatchQueue = .global(qos: .utility)) -> [pid_t] {
        let me = getpid()
        let candidates = processes.filter { $0.pid > 1 && $0.pid != me }
        guard !candidates.isEmpty else { return [] }

        // SIGTERM each; keep ONLY the ones we actually signalled, with a
        // start-time fingerprint so the later SIGKILL can detect pid recycling.
        var signalled: [(proc: ManagedProcess, startTime: UInt64?)] = []
        for p in candidates {
            let startTime = ProcessScanner.processStartTime(pid: p.pid)
            if kill(p.pid, SIGTERM) == 0 {
                signalled.append((p, startTime))
            } else {
                log.warn("SIGTERM \(p.pid) failed: \(String(cString: strerror(errno)))")
            }
        }
        guard !signalled.isEmpty else { return [] }

        queue.asyncAfter(deadline: .now() + grace) {
            for entry in signalled where kill(entry.proc.pid, 0) == 0 {
                // PID-recycle guard: force-kill only if BOTH the executable path and
                // the start time still match — a recycled pid (even same binary) has
                // a later start time and is skipped.
                let path = ProcessScanner.currentExecutablePath(pid: entry.proc.pid)
                let start = ProcessScanner.processStartTime(pid: entry.proc.pid)
                if path == entry.proc.executablePath && start == entry.startTime {
                    _ = kill(entry.proc.pid, SIGKILL)
                    log.info("SIGKILL \(entry.proc.pid) (survived SIGTERM)")
                } else {
                    log.warn("skip SIGKILL \(entry.proc.pid) — pid recycled (identity changed)")
                }
            }
        }
        log.info("reapUser signalled \(signalled.count) pid(s)")
        return signalled.map { $0.proc.pid }
    }

    /// Reap ROOT-owned pids via one admin prompt. Blocks on the password dialog,
    /// so call off the main thread. (pids are integers — no injection surface.)
    static func reapRootPrivileged(pids: [pid_t]) -> Result<String, PrivilegedRunner.RunError> {
        let targets = pids.filter { $0 > 1 }
        guard !targets.isEmpty else { return .success("") }
        let list = targets.map(String.init).joined(separator: " ")
        // TERM, brief settle, then KILL survivors. Ignore errors from already-gone pids.
        let inner = "/bin/kill -TERM \(list) 2>/dev/null; sleep 2; /bin/kill -KILL \(list) 2>/dev/null; true"
        return PrivilegedRunner.run("/bin/sh", ["-c", inner])
    }

    /// Whether a pid is still alive (and signalable by us).
    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}
