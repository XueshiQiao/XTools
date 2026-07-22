import Foundation
import Darwin

/// Thin wrapper around the `tmux` CLI. All work is synchronous and intended to
/// run off the main thread.
///
/// GUI apps (Dock / Finder launch) do not inherit a login shell environment.
/// tmux places its server socket under `/tmp/tmux-$UID/` (or `$TMUX_TMPDIR`),
/// while a GUI process often has a different `TMPDIR` (`/var/folders/...`).
/// If we let the child inherit that TMPDIR, the client can connect to the wrong
/// (empty) path and report "no sessions" even though Terminal's tmux is fine.
///
/// Fix: always force `TMUX_TMPDIR=/tmp` and pass an absolute `-S` socket path
/// discovered under `/tmp/tmux-$UID/` (preferring `default`).
enum TmuxCLI {

    private static let log = FileLog("Tmux")

    enum Error: Swift.Error, LocalizedError {
        case tmuxNotFound
        case noServer
        case nonZeroExit(status: Int32, stderr: String)
        case noClientAttached
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .tmuxNotFound:
                return L("tmux.error.notFound")
            case .noServer:
                return L("tmux.error.noServer")
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

    // MARK: - Socket discovery

    /// Socket paths the user might have a server on. Prefer `default`.
    static func discoverSockets() -> [String] {
        let uid = getuid()
        let dirs = [
            "/tmp/tmux-\(uid)",
            "/private/tmp/tmux-\(uid)",
        ]
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()
        for dir in dirs {
            // Resolve symlinks so /tmp vs /private/tmp de-dupe.
            let realDir = (dir as NSString).resolvingSymlinksInPath
            guard let names = try? fm.contentsOfDirectory(atPath: realDir) else { continue }
            for name in names {
                // Skip backup/noise names if any.
                if name.hasPrefix(".") { continue }
                let path = (realDir as NSString).appendingPathComponent(name)
                if seen.insert(path).inserted {
                    found.append(path)
                }
            }
        }
        // Prefer the conventional default socket first.
        found.sort { a, b in
            let aDef = (a as NSString).lastPathComponent == "default"
            let bDef = (b as NSString).lastPathComponent == "default"
            if aDef != bDef { return aDef && !bDef }
            return a < b
        }
        if found.isEmpty {
            found = ["/tmp/tmux-\(uid)/default"]
        }
        return found
    }

    // MARK: - Run

    /// Run a tmux subcommand against an explicit socket. Injects `-S` and a
    /// sanitized environment so GUI TMPDIR cannot redirect the client.
    ///
    /// Output goes to TEMP FILES, not pipes. In Sparkle-relaunched instances the
    /// tmux client's server-mediated stdout intermittently never reached our
    /// pipe (exit 0, 0 bytes — every poll, for the process's whole lifetime)
    /// while direct stderr writes survived; the tmux server verifiably sent the
    /// data ("file 1 sent 21, left 0" in its SIGUSR2 log). Files replace the
    /// pipe endpoint entirely, and the diagnostics below record the full scene
    /// if any variant of the loss ever shows up again.
    @discardableResult
    static func run(_ arguments: [String], socket: String) throws -> String {
        guard let bin = resolveBinary() else { throw Error.tmuxNotFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        // Force absolute socket — do not rely on TMPDIR / TMUX_TMPDIR.
        proc.arguments = ["-S", socket] + arguments
        // Do not inherit whatever QoS band the app was launched in (a Sparkle
        // relaunch starts the app in the background band).
        proc.qualityOfService = .userInitiated
        // Explicit stdin: never let the client inherit the app's stdin.
        proc.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        // Prevent the client from building a different socket dir from GUI TMPDIR.
        env["TMUX_TMPDIR"] = "/tmp"
        env["TMPDIR"] = "/tmp"
        // Avoid inheriting an attached-client TMUX=… which can confuse some cmds.
        env.removeValue(forKey: "TMUX")
        proc.environment = env

        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let token = UUID().uuidString
        let outURL = tmpDir.appendingPathComponent("xtools-tmux-\(token).out")
        let errURL = tmpDir.appendingPathComponent("xtools-tmux-\(token).err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outFH = try? FileHandle(forWritingTo: outURL),
              let errFH = try? FileHandle(forWritingTo: errURL) else {
            log.error("cannot open temp output files for tmux run")
            throw Error.tmuxNotFound
        }
        proc.standardOutput = outFH
        proc.standardError = errFH
        do {
            try proc.run()
        } catch {
            outFH.closeFile(); errFH.closeFile()
            log.error("failed to launch \(bin): \(error)")
            throw Error.tmuxNotFound
        }
        proc.waitUntilExit()
        outFH.closeFile()
        errFH.closeFile()
        let stdoutData = (try? Data(contentsOf: outURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: errURL)) ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            log.warn("tmux -S \(socket) \(arguments.joined(separator: " ")) → \(proc.terminationStatus): \(stderr)")
            throw Error.nonZeroExit(status: proc.terminationStatus, stderr: stderr)
        }
        // Black-box recorder: a live socket answering list-sessions with exit 0
        // and ZERO bytes is the lost-output signature. It can also be a
        // legitimately session-less server (exit-empty off), so throttle to one
        // line per minute instead of flagging every 4-second poll.
        if stdoutData.isEmpty, arguments.first == "list-sessions" {
            emptyOKLock.lock()
            let shouldLog = Date().timeIntervalSince(lastEmptyOKLog) > 60
            if shouldLog { lastEmptyOKLog = Date() }
            emptyOKLock.unlock()
            if shouldLog {
                log.error("EMPTY-OK: tmux -S \(socket) \(arguments.joined(separator: " ")) exit=0 "
                    + "reason=\(proc.terminationReason.rawValue) errBytes=\(stderrData.count) "
                    + "socketExists=\(fm.fileExists(atPath: socket)) pid=\(ProcessInfo.processInfo.processIdentifier)")
            }
        }
        return stdout
    }

    private static let emptyOKLock = NSLock()
    private static var lastEmptyOKLog = Date.distantPast

    /// Convenience: try discovered sockets until one answers.
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let sockets = discoverSockets()
        var lastError: Swift.Error = Error.noServer
        for socket in sockets {
            do {
                return try run(arguments, socket: socket)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Snapshot

    private static let sep = "\u{1f}"

    static func fetchSnapshot() throws -> TmuxSnapshot {
        guard let bin = resolveBinary() else { throw Error.tmuxNotFound }

        let sockets = discoverSockets()
        log.debug("tmux sockets: \(sockets.joined(separator: ", "))")

        var best: TmuxSnapshot?
        var lastError: Swift.Error?

        for socket in sockets {
            do {
                let snap = try fetchSnapshot(socket: socket, binary: bin)
                log.debug("socket \(socket) → \(snap.sessions.count) session(s)")
                if best == nil || snap.sessions.count > (best?.sessions.count ?? -1) {
                    best = snap
                }
                // Prefer the first non-empty server (default is first in list).
                if !snap.sessions.isEmpty { break }
            } catch {
                lastError = error
                log.debug("socket \(socket) failed: \(error.localizedDescription)")
            }
        }

        if let best {
            log.debug("snapshot: \(best.sessions.count) sessions, \(best.clients.count) client(s) via \(best.tmuxPath)")
            return best
        }
        throw lastError ?? Error.noServer
    }

    private static func fetchSnapshot(socket: String, binary: String) throws -> TmuxSnapshot {
        let sessionFmt = [
            "#{session_id}", "#{session_name}", "#{session_attached}",
        ].joined(separator: sep)
        let sessionOut = try run(["list-sessions", "-F", sessionFmt], socket: socket)

        let windowFmt = [
            "#{session_id}", "#{session_name}", "#{window_id}",
            "#{window_index}", "#{window_name}", "#{window_active}",
        ].joined(separator: sep)
        let windowOut = try run(["list-windows", "-a", "-F", windowFmt], socket: socket)

        let paneFmt = [
            "#{session_id}", "#{session_name}", "#{window_id}", "#{window_name}",
            "#{pane_id}", "#{pane_index}", "#{pane_title}",
            "#{pane_current_command}", "#{pane_current_path}", "#{pane_active}",
        ].joined(separator: sep)
        let paneOut = try run(["list-panes", "-a", "-F", paneFmt], socket: socket)

        let clientFmt = ["#{client_activity}", "#{client_name}"].joined(separator: sep)
        let clientOut: String
        do {
            clientOut = try run(["list-clients", "-F", clientFmt], socket: socket)
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

        // Encode socket into tmuxPath for logs/diagnostics: "binary · socket".
        return TmuxSnapshot(
            sessions: sessions,
            clients: clients,
            tmuxPath: "\(binary) · \(socket)"
        )
    }

    // MARK: - Actions

    static func jump(to target: TmuxTarget, preferredClient: String? = nil) throws {
        let client: String
        if let preferredClient, !preferredClient.isEmpty {
            client = preferredClient
        } else {
            let snap = try fetchSnapshot()
            guard let first = snap.clients.first else { throw Error.noClientAttached }
            client = first
        }
        _ = try run(["switch-client", "-Z", "-c", client, "-t", target.tmuxFlag])
        log.info("jump client=\(client) → \(target.tmuxFlag)")
    }

    enum WindowPlacement: Equatable {
        case endOfSession(name: String)
        case beforeWindow(id: String)
        case afterWindow(id: String)
    }

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

    static func moveWindow(windowID: String, toSessionName: String) throws {
        try moveWindow(windowID: windowID, to: .endOfSession(name: toSessionName))
    }
}
