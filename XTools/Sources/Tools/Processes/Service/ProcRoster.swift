import Foundation
import Darwin

/// The IDENTITY layer: who is running, right now.
///
/// Everything here is an in-process syscall — `sysctl(KERN_PROC_ALL)` for the
/// roster and `proc_pidpath` / `proc_pidinfo` per pid. It needs no privilege, it
/// covers processes of EVERY uid (root included), and a full sweep of ~800
/// processes measured at ~6ms. That is why identity is read here and never
/// scraped out of `top`: `top`'s COMMAND column is truncated to 16 characters and
/// can contain spaces, which is unparseable, while this gives the full real path.
///
/// What it deliberately does NOT provide: CPU / memory / thread count. Those are
/// blocked by the kernel for other users' processes (`proc_pidinfo` returns EPERM
/// on every root-owned pid — measured 0/206) and come from the metrics layer.
enum ProcRoster {

    private static let log = FileLog("Processes")

    /// One identity sweep. Metrics fields come back nil — the store fills them by
    /// joining against a metrics sample.
    static func snapshot() -> [ProcRow] {
        var rows: [ProcRow] = []
        rows.reserveCapacity(900)

        // kernel_task (pid 0) is NOT in ProcessScanner's output: it filters
        // `pid > 0` (and must keep doing so — other callers rely on that guard).
        // But `top` DOES report pid 0, and it is the single most-asked-about
        // process on macOS. Synthesize its row here so the join finds a partner
        // and the AI can actually explain it.
        rows.append(kernelTaskRow())

        for p in ProcessScanner.snapshot() {
            // Zombies are dead. They hold no memory, burn no CPU, have no path, and
            // cannot be signalled — only the parent that forgot them can clear one.
            // Listing them ("pid 80643 · 0.0 MB") is noise that reads like a bug, and
            // there is nothing here for the tool to explain or for the user to do.
            // (Measured: 9 of them on this machine right now.)
            if p.isZombie { continue }

            let path = p.executablePath
            rows.append(ProcRow(
                pid: p.pid,
                ppid: p.ppid,
                uid: p.uid,
                executablePath: path,
                // nil start time (process exited mid-sweep) → 0. It only ever makes
                // the identity *more* likely to be seen as changed, which fails
                // safe: the action layer refuses to signal on a fingerprint miss.
                startTime: startTime(pid: p.pid) ?? 0,
                name: p.name,
                isAppleSystem: isSystemProcess(path: path),
                cpuPercent: nil,
                memoryBytes: nil,
                threadCount: nil
            ))
        }
        return rows
    }

    /// `kernel_task` — the kernel itself, wearing a pid. No executable, no argv,
    /// no bsdinfo (hence startTime 0), cannot be signalled.
    private static func kernelTaskRow() -> ProcRow {
        ProcRow(pid: 0, ppid: 0, uid: 0,
                executablePath: nil,
                startTime: 0,
                name: "kernel_task",
                isAppleSystem: true,
                cpuPercent: nil, memoryBytes: nil, threadCount: nil)
    }

    // MARK: - System-process filter (a DISPLAY filter, not a security verdict)

    /// Whether to treat a process as "system noise" for the *hide system processes*
    /// toggle and for keeping ~400 Apple daemons out of the user's way.
    ///
    /// This composes `KnownApps.isAppleSystem` (which answers a narrower question —
    /// "is this an Apple *bundle*" — and is used by LaunchManager for reap safety,
    /// so it is not widened here) with the daemon directories it does not cover:
    /// `launchd` is `/sbin/launchd`, `mDNSResponder` is `/usr/sbin/`.
    ///
    /// It is a path heuristic and nothing more. The authoritative "is this really
    /// Apple's" answer is the code signature, computed per-process in the facts
    /// panel — never from a path prefix.
    static func isSystemProcess(path: String?) -> Bool {
        guard let p = path, !p.isEmpty else {
            // No path: kernel_task, or a process that exited mid-sweep. Treat as
            // system so it doesn't clutter the default view.
            return true
        }
        if KnownApps.isAppleSystem(bundlePath: p, bundleID: nil) { return true }
        return p.hasPrefix("/usr/sbin/")
            || p.hasPrefix("/usr/bin/")
            || p.hasPrefix("/sbin/")
            || p.hasPrefix("/bin/")
    }

    // MARK: - Start time (works for EVERY uid — this is why it isn't ProcessScanner's)

    /// A process's start time in microseconds since the epoch: half of the
    /// instance fingerprint that keeps a recycled pid from being mistaken for the
    /// original (HR8.2).
    ///
    /// Read via `sysctl(KERN_PROC_PID)`, NOT `proc_pidinfo(PROC_PIDTBSDINFO)` as
    /// `ProcessScanner.processStartTime` does. That difference is load-bearing and
    /// was measured, not assumed: libproc denies PROC_PIDTBSDINFO for any process
    /// we do not own — `proc_pidinfo` on `opendirectoryd` (root) returns 0 with
    /// EPERM, while sysctl returns `1780642209.389673`. LaunchManager never
    /// noticed because it only ever fingerprints processes of our own uid.
    ///
    /// This tool lists and signals EVERY uid, so a libproc-based fingerprint would
    /// be 0 for all ~200 root processes — and since the action layer refuses to
    /// signal on a fingerprint it cannot confirm, the entire root column of §7's
    /// table would silently never work. sysctl is not permission-gated and returns
    /// the IDENTICAL value for processes we do own (verified on our own pid), so
    /// one source works for the whole list.
    static func startTime(pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        // A pid that has exited comes back as a zero-filled struct, not an error.
        guard kp.kp_proc.p_pid == pid else { return nil }
        let tv = kp.kp_proc.p_un.__p_starttime
        return UInt64(tv.tv_sec) &* 1_000_000 &+ UInt64(tv.tv_usec)
    }

    /// Re-read a single pid's instance fingerprint. Used by the action layer right
    /// before it signals, to prove the pid still names the same process instance.
    /// Uses the SAME start-time source as `snapshot()` — if the two disagreed,
    /// every signal would be refused (or, far worse, wrongly allowed).
    static func fingerprint(pid: pid_t) -> (startTime: UInt64?, path: String?) {
        (startTime(pid: pid), ProcessScanner.currentExecutablePath(pid: pid))
    }

    static func logSweep(count: Int, ms: Double) {
        log.info("roster sweep: \(count) processes in \(String(format: "%.1f", ms))ms")
    }
}
