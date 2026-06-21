import SwiftUI
import AppKit
import Combine
import Darwin

/// UI model for the Wake Locks tool: scans the current sleep-preventing power
/// assertions and lets the user end the holding process (macOS offers no API to
/// release another process's assertion — quitting the process is the only way).
final class WakeLocksStore: ObservableObject {

    @Published private(set) var holders: [AssertionHolder] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    private let work = DispatchQueue(label: "me.xueshi.xtools.wakelocks", qos: .userInitiated)

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let result = AssertionScanner.scan()
            DispatchQueue.main.async {
                self?.holders = result
                self?.isScanning = false
            }
        }
    }

    /// End the process holding the assertion. Apps are asked to quit gracefully
    /// (`NSRunningApplication.terminate`); other user-owned processes get SIGTERM.
    /// Root/system processes are left alone (need manual handling).
    func release(_ holder: AssertionHolder) {
        // Only end processes owned by the current user (root/other-user/unknown skipped).
        guard holder.canEnd else {
            actionMessage = String(format: L("wake.msg.rootSkip"), holder.processName)
            return
        }
        // Guard against PID reuse since the scan: re-verify the pid is still the
        // SAME process instance (start time + executable path) before ending it.
        let curStart = ProcessScanner.processStartTime(pid: holder.pid)
        let curPath = ProcessScanner.currentExecutablePath(pid: holder.pid)
        guard curStart == holder.startTime, curPath == holder.executablePath else {
            actionMessage = String(format: L("wake.msg.changed"), holder.processName)
            refresh()
            return
        }

        if holder.isApp, let app = NSRunningApplication(processIdentifier: holder.pid) {
            let ok = app.terminate()
            actionMessage = String(format: L(ok ? "wake.msg.quit" : "wake.msg.failed"), holder.processName)
        } else {
            let proc = ManagedProcess(pid: holder.pid, ppid: 0, uid: holder.uid ?? getuid(),
                                      executablePath: holder.executablePath)
            let signalled = ProcessReaper.reapUser([proc])
            actionMessage = String(format: L(signalled.isEmpty ? "wake.msg.failed" : "wake.msg.ended"), holder.processName)
        }
        Analytics.trackLaunchAction(kind: "wake_release", scope: "user")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    func revealInFinder(_ holder: AssertionHolder) {
        guard let p = holder.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
