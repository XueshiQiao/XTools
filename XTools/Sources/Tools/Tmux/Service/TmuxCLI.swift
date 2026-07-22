import Foundation

/// Thin wrapper around the `tmux` CLI. All work is synchronous and intended to
/// run off the main thread. Uses absolute binary paths so the sandboxed-looking
/// GUI process still finds Homebrew tmux without a login-shell PATH.
///
/// Self-contained: nothing outside `Tools/Tmux/` depends on this.
enum TmuxCLI {

    private static let log = FileLog("Tmux")

    enum Error: Swift.Error, LocalizedError {
        case tmuxNotFound
        case nonZeroExit(status: Int32, stderr: String)
        case noClientAttached
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .tmuxNotFound:
                return L("tmux.error.notFound")
            case .nonZeroExit(_, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? L("tmux.error.commandFailed") : trimmed
            case .noClientAttached:
                return L("tmux.error.noClient")
            case .parseFailed(let detail):
                return detail
            }
        }
    }

    // MARK: - Binary discovery

    /// Common install locations + PATH lookup. Cached after first success.
    private static var cachedPath: String?

    static func resolveBinary() -> String? {
        if let cachedPath { return cachedPath }
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            cachedPath = path
            return path
        }
        // Last resort: `which tmux` with a sane PATH.
        if let fromWhich = which("tmux") {
            cachedPath = fromWhich
            return fromWhich
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let path = env["PATH"] ?? ""
        env["PATH"] = (extras + [path]).joined(separator: ":")
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    // MARK: - Run

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        guard let bin = resolveBinary() else { throw Error.tmuxNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            log.error("failed to launch \(bin): \(error)")
            throw Error.tmuxNotFound
        }
        // Drain pipes while the child runs — if we wait first, a large listing
        // can fill the pipe buffer and deadlock both sides.
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            log.warn("tmux \(arguments.joined(separator: " ")) → \(proc.terminationStatus): \(stderr)")
            throw Error.nonZeroExit(status: proc.terminationStatus, stderr: stderr)
        }
        return stdout
    }

    // MARK: - Snapshot

    /// Field separator that is extremely unlikely to appear in names/titles.
    private static let sep = "\u{1f}"

    static func fetchSnapshot() throws -> TmuxSnapshot {
        guard let bin = resolveBinary() else { throw Error.tmuxNotFound }

        // Sessions
        let sessionFmt = [
            "#{session_id}", "#{session_name}", "#{session_attached}",
        ].joined(separator: sep)
        let sessionOut = try run(["list-sessions", "-F", sessionFmt])

        // Windows (all)
        let windowFmt = [
            "#{session_id}", "#{session_name}", "#{window_id}",
            "#{window_index}", "#{window_name}", "#{window_active}",
        ].joined(separator: sep)
        let windowOut = try run(["list-windows", "-a", "-F", windowFmt])

        // Panes (all)
        let paneFmt = [
            "#{session_id}", "#{session_name}", "#{window_id}", "#{window_name}",
            "#{pane_id}", "#{pane_index}", "#{pane_title}",
            "#{pane_current_command}", "#{pane_current_path}", "#{pane_active}",
        ].joined(separator: sep)
        let paneOut = try run(["list-panes", "-a", "-F", paneFmt])

        // Clients (most-recently-active first)
        let clientFmt = ["#{client_activity}", "#{client_name}"].joined(separator: sep)
        let clientOut: String
        do {
            clientOut = try run(["list-clients", "-F", clientFmt])
        } catch {
            clientOut = ""
        }

        var panesByWindow: [String: [TmuxPaneNode]] = [:]
        for line in paneOut.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: Character(sep), omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 10 else { continue }
            let pane = TmuxPaneNode(
                id: f[4],
                index: Int(f[5]) ?? 0,
                title: f[6],
                currentCommand: f[7],
                currentPath: f[8],
                active: f[9] == "1",
                windowID: f[2],
                sessionID: f[0],
                sessionName: f[1],
                windowName: f[3]
            )
            panesByWindow[pane.windowID, default: []].append(pane)
        }
        for key in panesByWindow.keys {
            panesByWindow[key]?.sort { $0.index < $1.index }
        }

        var windowsBySession: [String: [TmuxWindowNode]] = [:]
        for line in windowOut.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: Character(sep), omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            let winID = f[2]
            let win = TmuxWindowNode(
                id: winID,
                index: Int(f[3]) ?? 0,
                name: f[4],
                sessionID: f[0],
                sessionName: f[1],
                active: f[5] == "1",
                panes: panesByWindow[winID] ?? []
            )
            windowsBySession[win.sessionID, default: []].append(win)
        }
        for key in windowsBySession.keys {
            windowsBySession[key]?.sort { $0.index < $1.index }
        }

        var sessions: [TmuxSessionNode] = []
        for line in sessionOut.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: Character(sep), omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            let sid = f[0]
            sessions.append(TmuxSessionNode(
                id: sid,
                name: f[1],
                attached: f[2] != "0",
                windows: windowsBySession[sid] ?? []
            ))
        }
        // Stable-ish UI order: attached first, then name.
        sessions.sort { a, b in
            if a.attached != b.attached { return a.attached && !b.attached }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        var clientRows: [(activity: Int, name: String)] = []
        for line in clientOut.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: Character(sep), omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            clientRows.append((Int(f[0]) ?? 0, f[1]))
        }
        clientRows.sort { $0.activity > $1.activity }
        let clients = clientRows.map(\.name)

        log.debug("snapshot: \(sessions.count) sessions, \(clients.count) client(s) via \(bin)")
        return TmuxSnapshot(sessions: sessions, clients: clients, tmuxPath: bin)
    }

    // MARK: - Actions

    /// Switch the most-recently-active attached client to a session / window / pane.
    /// `switch-client -t` accepts pane targets (`%N`) and will change session+window+pane.
    static func jump(to target: TmuxTarget, preferredClient: String? = nil) throws {
        let client: String
        if let preferredClient, !preferredClient.isEmpty {
            client = preferredClient
        } else {
            let snap = try fetchSnapshot()
            guard let first = snap.clients.first else { throw Error.noClientAttached }
            client = first
        }
        // -Z keeps zoom if the destination window was zoomed.
        _ = try run(["switch-client", "-Z", "-c", client, "-t", target.tmuxFlag])
        log.info("jump client=\(client) → \(target.tmuxFlag)")
    }

    /// Where a dragged window should land. Backed by `move-window -b/-a/-t`.
    enum WindowPlacement: Equatable {
        /// Append at the next free index of `sessionName` (`session:`).
        case endOfSession(name: String)
        /// Insert immediately before the window with this `@id` (`move-window -b`).
        case beforeWindow(id: String)
        /// Insert immediately after the window with this `@id` (`move-window -a`).
        case afterWindow(id: String)
    }

    /// Move a window (`@id`) to a placement. `-d` avoids selecting it so the
    /// user's current focus is not stolen mid-organize. Same-session reorder
    /// and cross-session moves both use this path.
    static func moveWindow(windowID: String, to placement: WindowPlacement) throws {
        var args = ["move-window", "-d", "-s", windowID]
        switch placement {
        case .endOfSession(let name):
            args += ["-t", "\(name):"]
        case .beforeWindow(let destID):
            args += ["-b", "-t", destID]
        case .afterWindow(let destID):
            args += ["-a", "-t", destID]
        }
        _ = try run(args)
        log.info("move-window \(windowID) → \(placement)")
    }

    /// Convenience: append to the end of a session (context-menu path).
    static func moveWindow(windowID: String, toSessionName: String) throws {
        try moveWindow(windowID: windowID, to: .endOfSession(name: toSessionName))
    }
}
