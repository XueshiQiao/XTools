import Foundation

/// Reads, parses, and (with admin authorization) safely rewrites `/etc/hosts`.
///
/// `/etc/hosts` is world-readable, so reading + parsing needs no privilege. Only
/// the *write* needs root — and a write to a system file must never lose data, so
/// we ALWAYS back the original up to `/etc/hosts.bak` first, in the SAME
/// privileged session, before overwriting. We never delete the file.
///
/// Privileged writes go through `PrivilegedRunner` (one admin password prompt),
/// the same path the Launch Manager uses — we don't reinvent the prompt.
enum HostsFile {

    private static let log = FileLog("HostsFile")
    static let path = "/etc/hosts"
    static let backupPath = "/etc/hosts.bak"

    enum WriteError: LocalizedError {
        case cancelled
        case tempWriteFailed(String)
        case privileged(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:               return L("dns.hosts.save.cancelled")
            case .tempWriteFailed(let m):  return String(format: L("dns.hosts.save.tempFailed"), m)
            case .privileged(let m):       return String(format: L("dns.hosts.save.failed"), m)
            }
        }
    }

    // MARK: - Read

    /// The raw `/etc/hosts` contents, or nil if it can't be read.
    static func readRaw() -> String? {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            log.error("failed to read \(path): \(error)")
            return nil
        }
    }

    /// Parse the host map entries from raw contents, skipping comments (`#…`) and
    /// blank lines. Each non-comment line is `IP  hostname [hostname…]`.
    static func parse(_ raw: String) -> [HostEntry] {
        var entries: [HostEntry] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            // Drop any trailing inline comment, then trim.
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }   // need an IP + at least one host
            let ip = tokens[0]
            let hostnames = Array(tokens[1...])
            entries.append(HostEntry(ip: ip, hostnames: hostnames))
        }
        return entries
    }

    // MARK: - Write (privileged, with backup)

    /// Overwrite `/etc/hosts` with `newContents`, backing the current file up to
    /// `/etc/hosts.bak` first — all inside ONE admin authorization. Blocks on the
    /// password prompt, so call off the main thread.
    ///
    /// Strategy: write the new contents to a temp file WE own (no privilege), then
    /// in a single privileged `/bin/sh -c` do
    /// `cp /etc/hosts /etc/hosts.bak && cp <temp> /etc/hosts`, then clean up the
    /// temp file. The backup happens before the overwrite, so the original is
    /// never lost even if the second copy fails.
    static func write(_ newContents: String) -> Result<Void, WriteError> {
        // 1. Stage the new contents in a temp file owned by the current user.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtools-hosts-\(UUID().uuidString).txt")
        do {
            try newContents.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("failed to stage temp hosts file: \(error)")
            return .failure(.tempWriteFailed(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 2. One privileged session: back up, then overwrite. `cp` preserves the
        //    target path/inode semantics fine for /etc/hosts; we keep mode 644.
        //    The && chain means the overwrite only runs if the backup succeeded.
        let inner = "/bin/cp \(shellQuote(path)) \(shellQuote(backupPath)) && "
                  + "/bin/cp \(shellQuote(tempURL.path)) \(shellQuote(path)) && "
                  + "/bin/chmod 644 \(shellQuote(path))"

        switch PrivilegedRunner.run("/bin/sh", ["-c", inner]) {
        case .success:
            log.info("wrote \(path) (backup at \(backupPath))")
            return .success(())
        case .failure(.cancelled):
            return .failure(.cancelled)
        case .failure(.failed(_, let message)):
            return .failure(.privileged(message))
        }
    }

    /// Single-quote an argument for embedding in a compound /bin/sh -c command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
