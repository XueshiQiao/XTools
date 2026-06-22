import Foundation
import Darwin

/// One network endpoint held by a process — a listening socket or an active
/// connection — as parsed from a single `lsof -F` file record. The fields mirror
/// the author's netstat-cat row (pid, process, protocol, local/remote addr:port,
/// state), assembled here from lsof's machine-readable `-F` output.
struct Connection: Identifiable, Hashable {
    /// Stable identity for a row: pid + fd uniquely names one open socket, so the
    /// list is diffable across refreshes without collapsing a process's many
    /// sockets into one.
    let id: String

    let pid: pid_t
    let command: String          // COMMAND from lsof (process name)
    let uid: uid_t?              // owning uid, nil if unknown
    let executablePath: String?  // resolved via proc_pidpath (for icon + kill identity)
    let startTime: UInt64?       // per-instance fingerprint, to detect pid reuse before a kill

    let proto: String            // "TCP" / "UDP" (lsof P field)
    let isIPv6: Bool

    let localAddr: String        // e.g. "127.0.0.1", "*", "[::1]"
    let localPort: String        // e.g. "3000", "*"
    let remoteAddr: String?      // nil for listeners
    let remotePort: String?      // nil for listeners
    let state: String?           // e.g. "LISTEN", "ESTABLISHED"; nil for stateless UDP

    let isListening: Bool        // LISTEN state, or a bound UDP socket with no peer

    /// How many identical sockets this row collapses (e.g. a process opening one
    /// mDNS *:5353 socket per network interface → many identical lsof rows). 1 = unique.
    var dupCount: Int = 1

    /// We only offer to kill processes owned by the CURRENT user. Root, other
    /// users, and uid-unknown processes are not kill-eligible from the simple
    /// (no-prompt) path — they route through the privileged runner instead.
    var isCurrentUser: Bool { uid != nil && uid == getuid() }

    /// Whether the Kill button is enabled at all. We can always offer a kill for
    /// a real pid: current-user processes are signalled directly, root/other-user
    /// processes route through the admin-password prompt. (pid 0/1 are never
    /// targets.) The DIFFERENCE between the two paths is conveyed by the help text
    /// and the confirmation, not by disabling the button.
    var canKill: Bool { pid > 1 }

    var runsAsRoot: Bool { uid == 0 }

    /// "127.0.0.1:3000" / "*:3000" / "[::1]:4321".
    var localDisplay: String { "\(localAddr):\(localPort)" }

    /// "127.0.0.1:443" or "—" for listeners.
    var remoteDisplay: String {
        guard let a = remoteAddr, let p = remotePort else { return "—" }
        return "\(a):\(p)"
    }
}
