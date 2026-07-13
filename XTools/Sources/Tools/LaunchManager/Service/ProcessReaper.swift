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

    /// An instance fingerprint a SHELL can re-check: `ps -o lstart=,comm=` for one
    /// pid. Start time + command, in a format both sides read the same way.
    ///
    /// It exists because the in-process fingerprint cannot survive the trip through
    /// the privileged path: the check happens here, but the signal is sent minutes
    /// later by a root shell, after the user has typed a password. Only a check
    /// INSIDE that shell closes the window.
    static func psFingerprint(pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "lstart=,comm=", "-p", String(pid)]
        p.environment = ["LC_ALL": "C"]        // stable date format, locale-independent
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// Reap ROOT-owned pids via one admin prompt. Blocks on the password dialog,
    /// so call off the main thread.
    ///
    /// `guards` maps a pid to the `psFingerprint` captured BEFORE the prompt. Any
    /// pid with a guard is re-verified inside the privileged shell immediately
    /// before each signal — and again after the grace period, because the pid can
    /// die and be recycled during those two seconds as easily as during the
    /// password dialog. A pid whose fingerprint changed is skipped, not killed.
    ///
    /// Without this, the whole in-process fingerprint check (HR8.2) is decorative
    /// on the root path: a user can leave the password dialog open for minutes,
    /// and macOS will happily hand the freed pid to something else in the meantime.
    /// pids and fingerprints both go through `PrivilegedRunner`'s shell quoting, so
    /// there is no injection surface even though `comm` is attacker-controlled.
    static func reapRootPrivileged(pids: [pid_t],
                                   force: Bool = true,
                                   guards: [pid_t: String] = [:]) -> Result<String, PrivilegedRunner.RunError> {
        let targets = pids.filter { $0 > 1 }
        guard !targets.isEmpty else { return .success("") }

        // Per pid: verify identity, signal, and (when forcing) verify AGAIN before
        // the SIGKILL. `sh` single-quoting is applied by PrivilegedRunner.
        var lines: [String] = ["set -u"]
        for pid in targets {
            let p = String(pid)
            if let want = guards[pid] {
                let q = shSingleQuote(want)
                lines.append("""
                cur=$(/bin/ps -o lstart=,comm= -p \(p) 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')
                if [ "$cur" = \(q) ]; then
                  /bin/kill -TERM \(p) 2>/dev/null || true
                """)
                if force {
                    lines.append("""
                      sleep 2
                      cur2=$(/bin/ps -o lstart=,comm= -p \(p) 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')
                      if [ "$cur2" = \(q) ]; then /bin/kill -KILL \(p) 2>/dev/null || true; fi
                    """)
                }
                lines.append("fi")
            } else {
                // No guard supplied (legacy callers): previous behaviour.
                lines.append("/bin/kill -TERM \(p) 2>/dev/null || true")
                if force {
                    lines.append("sleep 2; /bin/kill -KILL \(p) 2>/dev/null || true")
                }
            }
        }
        lines.append("true")
        return PrivilegedRunner.run("/bin/sh", ["-c", lines.joined(separator: "\n")])
    }

    /// Wrap a value in single quotes for /bin/sh (the canonical `'\''` escape).
    private static func shSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a pid is still alive (and signalable by us).
    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}
