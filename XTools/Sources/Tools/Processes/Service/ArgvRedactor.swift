import Foundation

/// Strips secrets out of a command line before it can leave the machine.
///
/// This exists because argv routinely carries live credentials — `--api-key=sk-…`,
/// `-H "Authorization: Bearer …"`, a Postgres URL with the password in it. The
/// user cannot know that before clicking, so a one-time "we send your process
/// info" notice is not informed consent on its own.
///
/// It is a HEURISTIC and it will miss things. That is exactly why it is not the
/// only defence: the redacted text is shown to the user, who confirms it, and can
/// withhold the arguments entirely. Two independent gates — automatic rules catch
/// what rules can catch, the human catches what they can't (an internal hostname,
/// a client's name, an unreleased project path).
///
/// Bias: over-redact. Hiding one harmless flag costs nothing. Leaking one key is
/// unrecoverable.
///
/// Pure functions only — no I/O, no state — so it can be exercised directly.
enum ArgvRedactor {

    /// What replaces a secret. Visible on purpose: the user must be able to SEE
    /// that something was withheld, and where.
    static let mask = "‹redacted›"

    struct Result: Equatable {
        let arguments: [String]
        /// How many values were masked. Surfaced in the UI so the redaction is
        /// never silent.
        let redactedCount: Int
        /// True when the text was cut to fit the length cap.
        let wasTruncated: Bool
    }

    /// Keys whose VALUE is a secret, whatever the value looks like.
    private static let secretKeyPattern = try! NSRegularExpression(
        pattern: "(?i)(api[-_]?key|access[-_]?token|auth[-_]?token|token|secret|password|passwd|pwd|auth|credential|session|cookie|bearer|private[-_]?key)",
        options: []
    )

    /// Flags whose NEXT argument is the secret (`--password hunter2`).
    private static let secretFlagPattern = try! NSRegularExpression(
        pattern: "^-{1,2}(?i)(p|pass|password|passwd|pwd|token|secret|key|api[-_]?key|auth)$",
        options: []
    )

    /// Redact a command line. `homeDirectory` is replaced with `~` so the payload
    /// never carries the account name.
    static func redact(_ argv: [String],
                       homeDirectory: String = NSHomeDirectory(),
                       maxTotalLength: Int = 2048,
                       maxFieldLength: Int = 512) -> Result {
        var out: [String] = []
        var count = 0
        var maskNext = false

        for raw in argv {
            var arg = raw

            // The previous token was `--password`; this token IS the value.
            if maskNext {
                maskNext = false
                out.append(mask)
                count += 1
                continue
            }
            if isSecretFlag(arg) {
                maskNext = true
                out.append(arg)
                continue
            }

            var didMask = false

            // key=value where the key names a secret → drop the value, keep the key
            // so the reader (and the model) can still see WHICH flag was withheld.
            if let eq = arg.firstIndex(of: "="), eq != arg.startIndex {
                let key = String(arg[arg.startIndex..<eq])
                if matches(secretKeyPattern, key) {
                    arg = key + "=" + mask
                    didMask = true
                }
            }

            // `Header: value` — the shape a credential takes on nearly every curl
            // command line: `-H "Authorization: Bearer eyJ…"`, `-H "Cookie: session=…"`.
            // It arrives as ONE argv element, and every other rule misses it: `-H`
            // is not a secret flag name, there is no `=` before the secret, and the
            // entropy rule deliberately skips anything containing a space. So the
            // token would have gone out in the clear — the single most common way a
            // live credential actually appears in argv.
            if !didMask, let colon = arg.firstIndex(of: ":"), colon != arg.startIndex {
                let header = String(arg[arg.startIndex..<colon])
                if matches(secretKeyPattern, header) {
                    arg = header + ": " + mask
                    didMask = true
                }
            }

            // A bare `Bearer <token>` / `Basic <blob>` anywhere in the argument.
            if !didMask, let stripped = maskAuthScheme(arg) {
                arg = stripped
                didMask = true
            }

            // scheme://user:pass@host → scheme://host
            if !didMask, let stripped = stripURLUserInfo(arg) {
                arg = stripped
                didMask = true
            }

            // A bare high-entropy blob — a token pasted as a positional argument.
            if !didMask, looksLikeSecret(arg) {
                arg = mask
                didMask = true
            }

            if didMask { count += 1 }

            // Never leak the account name via a home path.
            arg = arg.replacingOccurrences(of: homeDirectory, with: "~")

            if arg.count > maxFieldLength {
                arg = String(arg.prefix(maxFieldLength)) + "…"
            }
            out.append(arg)
        }

        // Cap the whole line. TRUNCATE, never drop — a silently shortened command
        // line must still look shortened.
        var truncated = false
        var total = 0
        var capped: [String] = []
        for arg in out {
            if total + arg.count + 1 > maxTotalLength {
                truncated = true
                break
            }
            total += arg.count + 1
            capped.append(arg)
        }
        if truncated { capped.append("…") }

        return Result(arguments: capped, redactedCount: count, wasTruncated: truncated)
    }

    // MARK: - Rules

    private static func isSecretFlag(_ arg: String) -> Bool {
        matches(secretFlagPattern, arg)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }

    /// `… Bearer eyJhb…` → `… Bearer ‹redacted›`. Keeps the scheme word so the
    /// reader (and the model) can still see that a credential was there.
    private static let authSchemePattern = try! NSRegularExpression(
        pattern: "(?i)\\b(bearer|basic|token)\\s+\\S+", options: []
    )

    private static func maskAuthScheme(_ arg: String) -> String? {
        let range = NSRange(arg.startIndex..<arg.endIndex, in: arg)
        guard let m = authSchemePattern.firstMatch(in: arg, options: [], range: range),
              let full = Range(m.range, in: arg),
              let scheme = Range(m.range(at: 1), in: arg) else { return nil }
        return arg.replacingCharacters(in: full, with: "\(arg[scheme]) \(mask)")
    }

    /// `postgres://user:pass@host/db` → `postgres://host/db`.
    private static func stripURLUserInfo(_ arg: String) -> String? {
        guard let schemeEnd = arg.range(of: "://") else { return nil }
        let afterScheme = arg[schemeEnd.upperBound...]
        guard let at = afterScheme.firstIndex(of: "@") else { return nil }
        let userInfo = afterScheme[afterScheme.startIndex..<at]
        // A bare `user@host` (no colon) is not a credential — that's just ssh.
        guard userInfo.contains(":") else { return nil }
        return String(arg[arg.startIndex..<schemeEnd.upperBound]) + String(afterScheme[afterScheme.index(after: at)...])
    }

    /// A long, high-entropy, token-shaped string. Deliberately conservative about
    /// what it will NOT flag: paths and URLs are full of long alphanumeric runs.
    static func looksLikeSecret(_ s: String) -> Bool {
        guard s.count >= 20 else { return false }
        // Anything with a path separator or a space is not a bare token.
        if s.contains("/") || s.contains(" ") || s.contains("\\") { return false }

        // Known prefixes are secrets regardless of entropy.
        let lower = s.lowercased()
        for prefix in ["sk-", "pk-", "ghp_", "gho_", "github_pat_", "xox", "aki", "eyj"] where lower.hasPrefix(prefix) {
            return true
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-."))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Must actually mix cases/digits — a long lowercase word is not a token.
        let hasDigit = s.contains(where: \.isNumber)
        let hasUpper = s.contains(where: \.isUppercase)
        let hasLower = s.contains(where: \.isLowercase)
        guard hasDigit && (hasUpper || hasLower) else { return false }

        return shannonEntropy(s) >= 3.5
    }

    /// Bits of entropy per character. English words land around 2–3; a random
    /// base64/hex token lands above 4.
    static func shannonEntropy(_ s: String) -> Double {
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0.0) { acc, count in
            let p = Double(count) / n
            return acc - p * log2(p)
        }
    }
}
