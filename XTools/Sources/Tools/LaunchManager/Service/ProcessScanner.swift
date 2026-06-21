import Foundation
import AppKit
import Darwin

/// Enumerates running processes via `sysctl(KERN_PROC_ALL)` and resolves each
/// executable path via `proc_pidpath`. No special privilege is needed to LIST
/// every pid, but `proc_pidpath` only succeeds for processes we own — root
/// processes typically resolve to a nil path (handled by the plist inventory).
enum ProcessScanner {

    private static let log = FileLog("ProcessScanner")

    /// Snapshot of all current processes.
    static func snapshot() -> [ManagedProcess] {
        let raw = rawProcessList()
        return raw.map { p in
            ManagedProcess(pid: p.pid, ppid: p.ppid, uid: p.uid,
                           executablePath: executablePath(pid: p.pid))
        }
    }

    /// Processes whose executable lives inside `bundlePath` (a `…/Foo.app`).
    /// `proc_pidpath` returns symlink-resolved real paths (e.g. `/private/tmp/…`),
    /// so we resolve the bundle path the same way before prefix-matching.
    static func processes(inBundle bundlePath: String, from snapshot: [ManagedProcess]) -> [ManagedProcess] {
        let resolved = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        let prefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
        return snapshot.filter { ($0.executablePath ?? "").hasPrefix(prefix) }
    }

    /// Is the MAIN app of `bundlePath` currently running? Checks the GUI app list
    /// (LaunchServices) by bundle URL first, then falls back to scanning for a
    /// process running the bundle's main executable.
    static func isMainAppRunning(bundlePath: String, bundleID: String?, snapshot: [ManagedProcess]) -> Bool {
        let resolvedPath = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().standardizedFileURL.path
        for app in NSWorkspace.shared.runningApplications {
            if let bid = bundleID, app.bundleIdentifier == bid { return true }
            // Compare resolved PATH strings, not URL objects — a trailing-slash
            // difference between the two URLs would make `==` spuriously fail and
            // mislabel a running app as "not running" (→ premature reap).
            if app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == resolvedPath { return true }
        }
        if let mainExec = mainExecutablePath(bundlePath: bundlePath) {
            if snapshot.contains(where: { $0.executablePath == mainExec }) { return true }
        }
        return false
    }

    /// `<bundle>/Contents/MacOS/<CFBundleExecutable>` if resolvable, symlink-resolved
    /// to match `proc_pidpath`'s real-path output.
    static func mainExecutablePath(bundlePath: String) -> String? {
        guard let bundle = Bundle(path: bundlePath),
              let exec = bundle.executableURL?.resolvingSymlinksInPath().path else { return nil }
        return exec
    }

    // MARK: - sysctl

    private struct RawProc { let pid: pid_t; let ppid: pid_t; let uid: uid_t }

    private static func rawProcessList() -> [RawProc] {
        let stride = MemoryLayout<kinfo_proc>.stride
        // The process table can grow between the size query and the fetch; retry
        // a few times on ENOMEM with a freshly-queried, slightly larger buffer.
        for _ in 0..<4 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 {
                log.error("sysctl size query failed: \(String(cString: strerror(errno)))")
                return []
            }
            let capacity = size / stride + 32   // headroom for growth between calls
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var fetched = capacity * stride

            let ret = procs.withUnsafeMutableBytes { buf -> Int32 in
                sysctl(&mib, u_int(mib.count), buf.baseAddress, &fetched, nil, 0)
            }
            if ret != 0 {
                if errno == ENOMEM { continue }   // grew past our buffer — retry bigger
                log.error("sysctl fetch failed: \(String(cString: strerror(errno)))")
                return []
            }

            // Never iterate past what we actually allocated, even if the kernel
            // reported a larger byte count.
            let count = min(fetched / stride, procs.count)
            var result: [RawProc] = []
            result.reserveCapacity(count)
            for i in 0..<count {
                let kp = procs[i]
                let pid = kp.kp_proc.p_pid
                guard pid > 0 else { continue }
                result.append(RawProc(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid))
            }
            return result
        }
        log.error("sysctl fetch failed after retries (table kept growing)")
        return []
    }

    /// Current symlink-resolved executable path for a pid (used to re-verify a pid
    /// hasn't been recycled before force-killing). Public wrapper over the resolver.
    static func currentExecutablePath(pid: pid_t) -> String? { executablePath(pid: pid) }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // 4 * MAXPATHLEN
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let raw = String(cString: buffer)
        // Normalize to the symlink-resolved real path so EVERY downstream
        // comparison (bundle grouping, rule matching, main-app detection) uses
        // one canonical form. proc_pidpath may return either the launch path
        // (e.g. /tmp/…) or the real path (/private/tmp/…); resolving here removes
        // the ambiguity. The executable exists (it's running), so this resolves.
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }
}
