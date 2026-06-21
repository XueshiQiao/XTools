import Foundation
import Darwin

/// Stop or persistently disable a launchd item.
///
/// - "Bootout" stops it right now (this session). User/system AGENTS live in the
///   user's `gui/<uid>` domain → no privilege needed. System DAEMONS live in the
///   `system` domain → one admin prompt.
/// - "Disable persistently" moves the plist aside to a `.bak` (never deletes, per
///   the project's data-safety rules) so it won't load next login. Plists under
///   `/Library` are root-owned → one admin prompt.
enum LaunchControl {

    private static let log = FileLog("LaunchControl")

    enum ControlError: LocalizedError {
        case commandFailed(String)
        var errorDescription: String? {
            switch self { case .commandFailed(let m): return m }
        }
    }

    // MARK: - Bootout (stop now)

    static func bootout(_ item: LaunchItem) -> Result<String, Error> {
        let uid = getuid()
        let target = item.domain.launchctlTarget(label: item.label, uid: uid)
        if item.domain == .systemDaemon {
            return PrivilegedRunner.run("/bin/launchctl", ["bootout", target]).mapError { $0 as Error }
        }
        return runUnprivileged("/bin/launchctl", ["bootout", target])
    }

    // MARK: - Disable completely (bootout + move plist aside)

    /// The right fix for a KeepAlive job: stop it now AND prevent it reloading.
    /// Just moving the plist isn't enough (a loaded KeepAlive job keeps running);
    /// just bootout isn't enough (it reloads at next login). Does both, in ONE
    /// privileged session for root items so the user is prompted at most once.
    static func disableCompletely(_ item: LaunchItem) -> Result<String, Error> {
        let uid = getuid()
        let target = item.domain.launchctlTarget(label: item.label, uid: uid)
        let dest = uniqueBackupPath(for: item.plistPath)

        switch item.domain {
        case .userAgent:
            // Both unprivileged. bootout may fail if not loaded — that's fine.
            _ = runUnprivileged("/bin/launchctl", ["bootout", target])
            do {
                try FileManager.default.moveItem(atPath: item.plistPath, toPath: dest)
                return .success(dest)
            } catch { return .failure(error) }

        case .systemAgent:
            // bootout runs in the user's gui domain (no password); only moving the
            // /Library plist needs root.
            _ = runUnprivileged("/bin/launchctl", ["bootout", target])
            return PrivilegedRunner.run("/bin/mv", [item.plistPath, dest])
                .map { _ in dest }.mapError { $0 as Error }

        case .systemDaemon:
            // One privileged session: bootout, then move the plist. Report failure
            // if the move fails (exit 1) OR if bootout genuinely failed — i.e. a
            // non-zero status other than 3 ("No such process" = already unloaded,
            // which is fine). This avoids reporting success while the daemon is
            // still running. The plist is still moved either way (so it won't load
            // next boot), but a real bootout failure surfaces to the user.
            let inner = "/bin/launchctl bootout \(shellQuote(target)) 2>/dev/null; bo=$?; "
                      + "/bin/mv \(shellQuote(item.plistPath)) \(shellQuote(dest)) || exit 1; "
                      + "[ \"$bo\" -eq 0 ] || [ \"$bo\" -eq 3 ] || exit 2"
            return PrivilegedRunner.run("/bin/sh", ["-c", inner])
                .map { _ in dest }.mapError { $0 as Error }
        }
    }

    // MARK: - Disable persistently (move plist aside)

    static func disablePersistently(_ item: LaunchItem) -> Result<String, Error> {
        let dest = uniqueBackupPath(for: item.plistPath)
        if item.plistRequiresRoot {
            return PrivilegedRunner.run("/bin/mv", [item.plistPath, dest])
                .map { _ in dest }
                .mapError { $0 as Error }
        }
        do {
            try FileManager.default.moveItem(atPath: item.plistPath, toPath: dest)
            log.info("moved \(item.plistPath) → \(dest)")
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Helpers

    private static func uniqueBackupPath(for path: String) -> String {
        var candidate = path + ".bak"
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = path + ".bak.\(n)"
            n += 1
        }
        return candidate
    }

    private static func runUnprivileged(_ launchPath: String, _ args: [String]) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return .failure(error) }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let message = err.isEmpty ? "exit \(process.terminationStatus)" : err.trimmingCharacters(in: .whitespacesAndNewlines)
        log.warn("\(launchPath) \(args.joined(separator: " ")) failed: \(message)")
        return .failure(ControlError.commandFailed(message))
    }

    /// Single-quote an argument for embedding in a compound /bin/sh -c command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
