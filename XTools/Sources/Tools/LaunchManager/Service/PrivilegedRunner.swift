import Foundation

/// Runs a shell command as root by asking macOS for an admin authorization,
/// which surfaces the standard system password prompt. Used ONLY for on-demand,
/// user-initiated root operations (disable a system daemon, kill a root process,
/// move a /Library plist aside) — never on a background loop, since you can't
/// prompt for a password every few seconds.
///
/// NOTE: this triggers an interactive password dialog, so it is exercised by the
/// user, not by automated verification. The continuous Guardian reaper does NOT
/// use this path; root continuous-reaping would need a separately-installed
/// privileged helper (a documented v2 limitation).
enum PrivilegedRunner {

    private static let log = FileLog("PrivilegedRunner")

    enum RunError: LocalizedError {
        case cancelled
        case failed(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Authorization was cancelled."
            case .failed(let code, let message): return "Privileged command failed (\(code)): \(message)"
            }
        }
    }

    /// Run a command with administrator privileges. Takes a discrete executable
    /// path + argument array so callers NEVER hand-build a shell string — every
    /// component is shell-quoted here, closing off command injection from values
    /// that originate in on-disk plists (e.g. a malicious launchd `Label`).
    /// Returns stdout on success. Blocks on the password prompt, so call off the
    /// main thread.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result<String, RunError> {
        let shellCommand = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let script = "do shell script \"\(appleScriptEscape(shellCommand))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failure(.failed(code: -1, message: error.localizedDescription))
        }
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // osascript reports a user cancel as "User canceled. (-128)".
        if err.contains("-128") || err.localizedCaseInsensitiveContains("cancel") {
            log.info("privileged command cancelled by user")
            return .failure(.cancelled)
        }
        log.error("privileged command failed: \(err)")
        return .failure(.failed(code: process.terminationStatus, message: err))
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wrap a single argument in single quotes for /bin/sh, escaping embedded
    /// single quotes the canonical `'\''` way.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
