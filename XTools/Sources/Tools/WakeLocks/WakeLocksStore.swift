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
        if holder.runsAsRoot {
            actionMessage = String(format: L("wake.msg.rootSkip"), holder.processName)
            return
        }
        if holder.isApp, let app = NSRunningApplication(processIdentifier: holder.pid) {
            app.terminate()
            actionMessage = String(format: L("wake.msg.quit"), holder.processName)
        } else {
            let proc = ManagedProcess(pid: holder.pid, ppid: 0, uid: getuid(),
                                      executablePath: holder.executablePath)
            ProcessReaper.reapUser([proc])
            actionMessage = String(format: L("wake.msg.ended"), holder.processName)
        }
        Analytics.trackLaunchAction(kind: "wake_release", scope: "user")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    func revealInFinder(_ holder: AssertionHolder) {
        guard let p = holder.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
