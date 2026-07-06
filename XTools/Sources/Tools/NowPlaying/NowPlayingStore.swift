import SwiftUI
import AppKit
import Combine
import Darwin

/// UI model for the Now Playing tool: scans which processes currently hold an
/// audio-output lock (are playing sound) and lets the user quit one to stop it
/// (macOS offers no API to pause another process's audio — quitting it is the
/// only way).
final class NowPlayingStore: ObservableObject {

    @Published private(set) var sources: [AudioSource] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    private let work = DispatchQueue(label: "me.xueshi.xtools.nowplaying", qos: .userInitiated)

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let result = NowPlayingScanner.scan()
            DispatchQueue.main.async {
                self?.sources = result
                self?.isScanning = false
            }
        }
    }

    /// Quit the app that's playing. GUI apps are asked to quit gracefully
    /// (`NSRunningApplication.terminate`); other user-owned processes get SIGTERM.
    /// Root/system processes are left alone (need manual handling).
    func quit(_ source: AudioSource) {
        guard source.canEnd else {
            actionMessage = String(format: L("nowplaying.msg.rootSkip"), source.processName)
            return
        }
        // Guard against pid reuse since the scan: re-verify the pid is still the
        // SAME process instance (start time + executable path) before ending it.
        let curStart = ProcessScanner.processStartTime(pid: source.pid)
        let curPath = ProcessScanner.currentExecutablePath(pid: source.pid)
        guard curStart == source.startTime, curPath == source.executablePath else {
            actionMessage = String(format: L("nowplaying.msg.changed"), source.processName)
            refresh()
            return
        }

        if source.isApp, let app = NSRunningApplication(processIdentifier: source.pid) {
            let ok = app.terminate()
            actionMessage = String(format: L(ok ? "nowplaying.msg.quit" : "nowplaying.msg.failed"), source.processName)
        } else {
            let proc = ManagedProcess(pid: source.pid, ppid: 0, uid: source.uid ?? getuid(),
                                      executablePath: source.executablePath)
            let signalled = ProcessReaper.reapUser([proc])
            actionMessage = String(format: L(signalled.isEmpty ? "nowplaying.msg.failed" : "nowplaying.msg.ended"), source.processName)
        }
        Analytics.trackLaunchAction(kind: "nowplaying_quit", scope: "user")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    func revealInFinder(_ source: AudioSource) {
        guard let p = source.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
