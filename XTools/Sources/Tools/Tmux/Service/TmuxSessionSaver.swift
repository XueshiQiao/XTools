import Foundation

/// Triggers the session snapshot that tmux-resurrect exposes as `prefix + C-s`.
///
/// Why we do NOT simulate the key press
/// ------------------------------------
/// `prefix + C-s` has no magic in it — it is just a binding, and the work is
/// done by the command it is bound to (`run-shell .../save.sh`). Sending the
/// keys with `send-keys` would need a target pane, could be swallowed or
/// interrupted by whatever program runs inside that pane, and has to survive
/// the user's own `bind C-b send-prefix` indirection. Reading the binding and
/// running its command touches no pane at all.
///
/// Why the command round-trips through a temp file
/// -----------------------------------------------
/// `list-keys` prints the command using tmux's own quoting rules, e.g.
/// `run-shell "/path with space/save.sh --flag 'x y'"`. Re-splitting that
/// string by hand breaks on the first quoted argument. `source-file` feeds it
/// back through the very parser that produced it, so the round-trip is exact.
///
/// This is also what makes the feature configurable without a setting of our
/// own: change `@resurrect-save`, move the TPM directory, or swap in another
/// plugin that binds a command — the button follows, because it reads the live
/// binding every time instead of hard-coding a script path.
enum TmuxSessionSaver {

    private static let log = FileLog("Tmux.Save")

    /// tmux-resurrect's own option for overriding the save key, and the default
    /// it falls back to (`scripts/variables.sh`: `default_save_key="C-s"`).
    private static let saveKeyOption = "@resurrect-save"
    static let defaultSaveKey = "C-s"

    enum Error: Swift.Error, LocalizedError {
        case noSaveBinding(keys: [String])

        var errorDescription: String? {
            switch self {
            case .noSaveBinding(let keys):
                return String(format: L("tmux.save.error.noBinding"),
                              keys.joined(separator: " / "))
            }
        }
    }

    // MARK: - Resolution

    /// The server the save runs against: the conventional `default` socket.
    static func defaultSocket() -> String {
        let sockets = TmuxCLI.discoverSockets()
        return sockets.first { ($0 as NSString).lastPathComponent == "default" }
            ?? sockets.first
            ?? "/tmp/tmux-\(getuid())/default"
    }

    /// The keys the save is bound to.
    ///
    /// `@resurrect-save` may hold several whitespace-separated keys — the plugin
    /// loops over them (`resurrect.tmux`: `for key in $key_bindings`) and binds
    /// each one, so `'S C-s'` really is two bindings, not a key named "S C-s".
    ///
    /// Throws rather than falling back: a failure here means tmux is missing or
    /// the server is unreachable, and that error has to reach the user instead
    /// of being reshaped into "no binding" further down.
    static func saveKeys(socket: String) throws -> [String] {
        let raw = try TmuxCLI.run(["show-options", "-gqv", saveKeyOption], socket: socket)
        let keys = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        return keys.isEmpty ? [defaultSaveKey] : keys
    }

    /// The command bound to `prefix + key`, exactly as tmux prints it, or nil
    /// when that key has no binding.
    ///
    /// Only the caller knows the server is alive (`saveKeys` proved it), so a
    /// failure here really is an unbound key rather than a tmux malfunction.
    static func command(forKey key: String, socket: String) -> String? {
        // Only ever the first line: a stray second line would otherwise be
        // appended to the command and executed too.
        guard let out = try? TmuxCLI.run(["list-keys", "-T", "prefix", key], socket: socket),
              let first = out.split(separator: "\n", omittingEmptySubsequences: true).first,
              let command = stripBindPrefix(first.trimmingCharacters(in: .whitespaces)),
              !command.isEmpty
        else {
            return nil
        }
        return command
    }

    /// `bind-key -r -T prefix C-s run-shell "…"` → `run-shell "…"`.
    ///
    /// Walks whitespace-delimited tokens up to `-T`, then drops the key table
    /// and the key itself; whatever follows is returned with its original
    /// spacing and quoting untouched, ready for `source-file`.
    static func stripBindPrefix(_ line: String) -> String? {
        var idx = line.startIndex
        let end = line.endIndex

        func skipSpaces() {
            while idx < end, line[idx] == " " || line[idx] == "\t" {
                idx = line.index(after: idx)
            }
        }
        func nextToken() -> String? {
            skipSpaces()
            guard idx < end else { return nil }
            let start = idx
            while idx < end, line[idx] != " ", line[idx] != "\t" {
                idx = line.index(after: idx)
            }
            return String(line[start..<idx])
        }

        guard nextToken() == "bind-key" else { return nil }
        // Flags such as `-r` / `-n` sit between the command and `-T`.
        var token = nextToken()
        while let t = token, t != "-T" { token = nextToken() }
        guard token == "-T" else { return nil }
        guard nextToken() != nil else { return nil }   // key table
        guard nextToken() != nil else { return nil }   // the key
        skipSpaces()
        guard idx < end else { return nil }
        return String(line[idx...])
    }

    // MARK: - Save

    /// Runs the bound save command and returns it for logging.
    ///
    /// Blocking and slow: with `@resurrect-capture-pane-contents on` the script
    /// walks every pane, which measured ~3s on a 26-window server. Call this off
    /// the main thread. `source-file` waits for the `run-shell` script to finish,
    /// so a clean return really does mean the snapshot is on disk.
    @discardableResult
    static func save(socket: String) throws -> String {
        // Throws the real tmux error (binary missing / no server) — and proves
        // the server is reachable, so an unbound key below is genuinely unbound.
        let keys = try saveKeys(socket: socket)
        guard let (key, command) = keys.lazy
            .compactMap({ k in Self.command(forKey: k, socket: socket).map { (k, $0) } })
            .first
        else {
            throw Error.noSaveBinding(keys: keys)
        }

        // Per-user temp dir (mode 700), not /tmp — the command string carries a
        // home-directory path and other local users have no business reading it.
        // The tmux server runs as the same uid, so it can read the file.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xtools-tmux-save-\(UUID().uuidString).tmux")
        try (command + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        log.info("saving session via prefix+\(key) → \(command)")
        _ = try TmuxCLI.run(["source-file", url.path], socket: socket)
        log.info("session saved")
        return command
    }
}
