import SwiftUI
import AppKit
import Combine
import Darwin

/// UI model for the Ports & Connections tool: scans `lsof` off the main thread,
/// publishes the rows, applies the search filter, and kills the owning process
/// (current-user directly, root/other-user through the admin-prompt path).
final class PortsStore: ObservableObject {

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    /// Search text — substring across process/pid/address/port, and also matches
    /// a bare port number or pid exactly. Bound by the view's `.searchable`.
    @Published var query: String = ""

    private let work = DispatchQueue(label: "me.xueshi.xtools.ports", qos: .userInitiated)

    // MARK: - Scan

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let result = PortScanner.scan()
            DispatchQueue.main.async {
                self?.connections = result
                self?.isScanning = false
            }
        }
    }

    // MARK: - Filter

    /// Listeners that match the current query.
    var listeners: [Connection] { filtered.filter { $0.isListening } }
    /// Active (non-listening) connections that match the current query.
    var active: [Connection] { filtered.filter { !$0.isListening } }

    private var filtered: [Connection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return connections }
        return connections.filter { row in
            // Bare number → match pid OR either port exactly (the common case:
            // "3000" should surface whoever is on :3000).
            if q.allSatisfy(\.isNumber) {
                if String(row.pid) == q { return true }
                if row.localPort == q { return true }
                if row.remotePort == q { return true }
            }
            // General substring across the visible fields.
            return row.command.lowercased().contains(q)
                || String(row.pid).contains(q)
                || row.proto.lowercased().contains(q)
                || row.localDisplay.lowercased().contains(q)
                || row.remoteDisplay.lowercased().contains(q)
                || (row.state?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Kill

    /// Kill the process owning a socket. Current-user processes are signalled
    /// directly (SIGTERM→SIGKILL); root/other-user processes route through one
    /// admin password prompt. Guards against PID reuse before killing.
    func kill(_ conn: Connection) {
        // Re-verify the pid is still the SAME process instance (start time +
        // executable path) before killing it — a recycled pid could now belong to
        // an unrelated process (even one running the same binary). Start time is
        // the decisive fingerprint for root processes, whose path resolves to nil.
        let curStart = ProcessScanner.processStartTime(pid: conn.pid)
        let curPath = ProcessScanner.currentExecutablePath(pid: conn.pid)
        if curStart != conn.startTime || curPath != conn.executablePath {
            actionMessage = String(format: L("ports.msg.changed"), conn.command)
            refresh()
            return
        }

        if conn.isCurrentUser {
            let proc = ManagedProcess(pid: conn.pid, ppid: 0,
                                      uid: conn.uid ?? getuid(),
                                      executablePath: conn.executablePath)
            let signalled = ProcessReaper.reapUser([proc])
            actionMessage = String(format: L(signalled.isEmpty ? "ports.msg.failed" : "ports.msg.killed"),
                                   conn.command)
            Analytics.trackLaunchAction(kind: "ports_kill", scope: "user")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        } else {
            // Root / other user — needs the admin prompt; run off the main thread.
            let pid = conn.pid
            let name = conn.command
            work.async { [weak self] in
                let result = ProcessReaper.reapRootPrivileged(pids: [pid])
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.actionMessage = String(format: L("ports.msg.killed"), name)
                        Analytics.trackLaunchAction(kind: "ports_kill", scope: "root")
                    case .failure(.cancelled):
                        self?.actionMessage = nil   // user backed out; stay quiet
                    case .failure:
                        self?.actionMessage = String(format: L("ports.msg.failed"), name)
                    }
                    self?.refresh()
                }
            }
        }
    }

    func revealInFinder(_ conn: Connection) {
        guard let p = conn.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
