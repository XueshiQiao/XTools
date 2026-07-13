import AppKit

/// Quit / Force Quit / Reveal in Finder / Copy path for one process row —
/// spec §7's 2×2 table, written out with no ambiguity:
///
///                    │ own process                │ root / other uid
///     ───────────────┼────────────────────────────┼──────────────────────────────
///     Quit           │ GUI app with a bundle →    │ SIGTERM via PrivilegedRunner
///                    │ NSRunningApplication       │ (one admin password prompt)
///                    │ .terminate() (can save);   │ + confirmation
///                    │ else ProcessReaper.reapUser│
///                    │ (SIGTERM, 2s grace)        │
///     Force Quit     │ ProcessReaper.reapUser     │ ProcessReaper
///                    │ grace 0 (SIGKILL)          │ .reapRootPrivileged (SIGKILL,
///                    │ + confirmation             │ one prompt) + confirmation
///
/// `kernel_task` (pid 0) and `launchd` (pid 1) never reach this code — the UI
/// disables all four actions on them (killing pid 1 panics the machine) — and
/// `perform` refuses them again anyway.
///
/// Kill mechanics are REUSED from LaunchManager (`ProcessReaper`,
/// `PrivilegedRunner`) — this file adds no second kill path, only the dispatch
/// and the fingerprint gate in front of it.
enum ProcActions {

    private static let log = FileLog("Processes")

    enum Kind {
        case quit
        case forceQuit
    }

    /// Every outcome carries a ready-to-show status-bar message; the store
    /// never has to interpret the case to talk to the user.
    enum Outcome: Equatable {
        /// The signal went out (or the app was asked to quit).
        case signalled(message: String)
        /// HR8.2: the pid no longer names the instance the user selected —
        /// NOTHING was signalled.
        case identityChanged(message: String)
        /// The admin password prompt was dismissed. Nothing was signalled.
        case cancelled(message: String)
        case failed(message: String)

        var message: String {
            switch self {
            case .signalled(let m), .identityChanged(let m),
                 .cancelled(let m), .failed(let m):
                return m
            }
        }
    }

    /// Signal (or ask) a process to go away. BLOCKS on the admin password
    /// prompt for non-own processes — always call off the main thread.
    ///
    /// HR8.2 — this is the one irreversible path in the whole tool, so before
    /// ANY signal is sent the pid is re-verified to still name the same process
    /// INSTANCE via the `(startTime + executablePath)` fingerprint. The user can
    /// select a row, walk away, and click Force Quit minutes later on a pid that
    /// meanwhile died and was recycled to something unrelated; on any mismatch
    /// we refuse and say so — a missed kill is recoverable, a wrong kill is not.
    static func perform(_ kind: Kind, on row: ProcRow) -> Outcome {
        guard row.canTerminate else {
            // The UI disables these; refuse anyway rather than trust a caller.
            return .failed(message: L("processes.action.protected"))
        }

        let fp = ProcRoster.fingerprint(pid: row.pid)
        guard let liveStart = fp.startTime,
              liveStart == row.startTime,
              fp.path == row.executablePath else {
            log.warn("\(label(kind)) pid \(row.pid) (\(row.name)) REFUSED: fingerprint mismatch (exited or pid recycled) — no signal sent")
            return .identityChanged(message: String(format: L("processes.action.exited"), row.name))
        }

        return row.isCurrentUser ? performOwn(kind, on: row)
                                 : performPrivileged(kind, on: row)
    }

    // MARK: - Own process (left column)

    private static func performOwn(_ kind: Kind, on row: ProcRow) -> Outcome {
        switch kind {
        case .quit:
            // A GUI app is ASKED to quit (the Apple Event a ⌘Q sends) so it can
            // save state and clean up. NSRunningApplication only exists for
            // LaunchServices-registered apps; combined with an owning .app bundle
            // that is the "GUI app" test.
            if row.owningAppBundlePath != nil,
               let app = NSRunningApplication(processIdentifier: row.pid) {
                // AppKit wants the main thread. perform() is normally called off it
                // (it has to be — the privileged path blocks on a password dialog),
                // but a main-thread caller must not deadlock on `sync`.
                let ok = Thread.isMainThread ? app.terminate()
                                             : DispatchQueue.main.sync { app.terminate() }
                log.info("quit pid \(row.pid) (\(row.name)): NSRunningApplication.terminate → \(ok)")
                return ok ? .signalled(message: String(format: L("processes.action.sent.quit"), row.name))
                          : .failed(message: String(format: L("processes.action.failed"), row.name))
            }
            let signalled = ProcessReaper.reapUser([managed(row)])
            log.info("quit pid \(row.pid) (\(row.name)): SIGTERM \(signalled.isEmpty ? "failed" : "sent")")
            return signalled.isEmpty
                ? .failed(message: String(format: L("processes.action.failed"), row.name))
                : .signalled(message: String(format: L("processes.action.sent.term"), row.name))

        case .forceQuit:
            // grace 0 → the SIGKILL sweep runs immediately after the SIGTERM.
            let signalled = ProcessReaper.reapUser([managed(row)], grace: 0)
            log.info("force quit pid \(row.pid) (\(row.name)): \(signalled.isEmpty ? "failed" : "signalled")")
            return signalled.isEmpty
                ? .failed(message: String(format: L("processes.action.failed"), row.name))
                : .signalled(message: String(format: L("processes.action.sent.kill"), row.name))
        }
    }

    // MARK: - root / other uid (right column) — one admin password prompt

    private static func performPrivileged(_ kind: Kind, on row: ProcRow) -> Outcome {
        // The in-process fingerprint above proved the pid is still our process AS OF
        // NOW — but the signal will not be sent until the user has typed a password
        // into a dialog that may sit open for minutes. So the identity is captured
        // in a form the ROOT SHELL can re-check for itself, immediately before it
        // signals (and again after the grace period). Without this second guard the
        // root column of §7 would still be able to kill a recycled pid — the very
        // thing HR8.2 exists to prevent.
        let guardFP = ProcessReaper.psFingerprint(pid: row.pid)
        if guardFP == nil {
            log.warn("\(label(kind)) pid \(row.pid) (\(row.name)) REFUSED: could not fingerprint for the privileged path — no signal sent")
            return .identityChanged(message: String(format: L("processes.action.exited"), row.name))
        }
        let guards = guardFP.map { [row.pid: $0] } ?? [:]

        let result = ProcessReaper.reapRootPrivileged(pids: [row.pid],
                                                      force: kind == .forceQuit,
                                                      guards: guards)
        switch result {
        case .success:
            log.info("privileged \(label(kind)) pid \(row.pid) (\(row.name)): signalled")
            let key = kind == .quit ? "processes.action.sent.term" : "processes.action.sent.kill"
            return .signalled(message: String(format: L(key), row.name))
        case .failure(.cancelled):
            log.info("privileged \(label(kind)) pid \(row.pid) (\(row.name)): cancelled at password prompt — no signal sent")
            return .cancelled(message: L("processes.action.cancelled"))
        case .failure(.failed(let code, _)):
            log.error("privileged \(label(kind)) pid \(row.pid) (\(row.name)) failed (code \(code))")
            return .failed(message: String(format: L("processes.action.failed"), row.name))
        }
    }

    // MARK: - Non-destructive actions

    static func revealInFinder(_ row: ProcRow) {
        guard let path = row.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @discardableResult
    static func copyPath(_ row: ProcRow) -> Bool {
        guard let path = row.executablePath else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        return true
    }

    // MARK: - Helpers

    private static func managed(_ row: ProcRow) -> ManagedProcess {
        ManagedProcess(pid: row.pid, ppid: row.ppid, uid: row.uid,
                       executablePath: row.executablePath)
    }

    private static func label(_ kind: Kind) -> String {
        kind == .quit ? "quit" : "force quit"
    }
}
