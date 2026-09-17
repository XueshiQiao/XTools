import Foundation

/// Resolves "the selected text IS a path on this Mac" — the local-filesystem
/// counterpart to `LinkResolver` (which only ever yields http/https).
///
/// Deliberately a separate resolver rather than a fifth `LinkResolver` tier: the
/// web-preview action keeps meaning "open the web link behind this selection", and
/// the path actions keep meaning "act on a file that exists on disk". Neither has
/// to know about the other, and neither can accidentally hand the other a URL it
/// can't handle.
///
/// Two deliberate limits:
///  - only the WHOLE trimmed selection is considered — we never hunt for a path
///    *inside* a paragraph, which would fire on prose containing a stray `/`;
///  - a path is accepted ONLY when it actually exists on disk, so an action can
///    never open something that isn't there.
enum PathResolver {

    /// An existing file or folder the selection pointed at.
    struct Target {
        let url: URL
        let isDirectory: Bool
    }

    /// Longest selection we'll even look at. `PATH_MAX` is 1024 on Darwin, so
    /// anything longer cannot be a path — and bailing early keeps a whole-article
    /// selection from doing string work on every capsule tap.
    private static let maxLength = 1024

    /// The selection as an existing local file/folder, or nil.
    static func resolve(_ text: String) -> Target? {
        for path in candidates(text) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            return Target(url: URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue),
                          isDirectory: isDirectory.boolValue)
        }
        return nil
    }

    // MARK: - Candidate paths

    /// The absolute paths this selection could plausibly mean, most-literal first.
    ///
    /// Two are produced because shell-escaping is ambiguous: `/tmp/a\ b` is
    /// `/tmp/a b` when it was escaped for a shell, but a backslash is ALSO a legal
    /// character in a macOS filename. Trying the literal reading first and the
    /// unescaped one only as a fallback means a real `a\ b` file still wins, and a
    /// path copied out of Terminal still resolves.
    private static func candidates(_ text: String) -> [String] {
        guard let base = normalize(text) else { return [] }
        var out = [base]
        if base.contains("\\") {
            let unescaped = unescapeShellPath(base)
            if unescaped != base { out.append(standardize(unescaped)) }
        }
        return out
    }

    /// Selection text → an absolute filesystem path, or nil if it can't be one.
    /// Handles the forms a path actually arrives in when you select one somewhere:
    /// wrapped in quotes (JSON, logs, chat), a `file://` URL (a browser address
    /// bar), or `~`-relative (docs, config files, READMEs).
    private static func normalize(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= maxLength else { return nil }
        // A path never spans lines. Bailing here also rejects whole paragraphs for
        // the cost of one scan, before any of the work below.
        guard !s.contains("\n"), !s.contains("\r") else { return nil }

        s = stripWrappingPair(s)
        guard !s.isEmpty else { return nil }

        if s.lowercased().hasPrefix("file://") {
            // `URL` percent-decodes the path for us (`%20` → space).
            guard let url = URL(string: s), url.isFileURL else { return nil }
            return url.standardizedFileURL.path
        }
        // Any other scheme (http:, mailto:, …) belongs to `LinkResolver`, not here.
        guard !s.contains("://") else { return nil }

        s = (s as NSString).expandingTildeInPath
        // A relative path has no meaningful base — a text selection carries no
        // "current directory" — so only absolute paths are accepted.
        guard s.hasPrefix("/") else { return nil }
        return standardize(s)
    }

    private static func standardize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Drop ONE matching pair of wrapping delimiters — the quotes and brackets that
    /// come along when a path is copied out of JSON, a log line, Markdown, or a
    /// Chinese-language document.
    private static func stripWrappingPair(_ s: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"),
            ("\u{201C}", "\u{201D}"),   // “ ”
            ("\u{2018}", "\u{2019}"),   // ‘ ’
            ("\u{300C}", "\u{300D}"),   // 「 」
            ("\u{300A}", "\u{300B}"),   // 《 》
            ("<", ">"), ("(", ")"), ("[", "]"),
        ]
        guard let first = s.first, let last = s.last, s.count >= 2 else { return s }
        for (open, close) in pairs where first == open && last == close {
            return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Undo shell escaping: a backslash before a non-alphanumeric character was put
    /// there by the shell (`My\ Files`, `a\(1\).png`), so drop it. A backslash
    /// before a letter or digit is left alone — that's a literal one.
    private static func unescapeShellPath(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var escaping = false
        for ch in s {
            if escaping {
                // Keep the backslash when it wasn't an escape after all.
                if ch.isLetter || ch.isNumber { out.append("\\") }
                out.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }   // trailing lone backslash
        return out
    }
}
