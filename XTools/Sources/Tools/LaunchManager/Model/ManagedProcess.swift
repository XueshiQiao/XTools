import Foundation

/// A running process as seen by the Launch Manager.
///
/// `executablePath` is resolved via `proc_pidpath`, which succeeds for processes
/// we own (our uid) but returns nothing for root-owned processes we lack the
/// privilege to inspect — so root daemons typically have a nil path and are
/// managed through the plist inventory instead of process grouping.
struct ManagedProcess: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let executablePath: String?

    var id: pid_t { pid }

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
