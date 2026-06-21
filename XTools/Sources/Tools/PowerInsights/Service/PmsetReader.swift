import Foundation

/// Runs `pmset` (read-only, no sudo, no prompt) and parses its output:
///
///  • `pmset -g`      → the active power/sleep settings (displaysleep, sleep, …).
///  • `pmset -g log`  → recent Sleep/Wake events, used for "what woke my Mac".
///
/// pmset's `-g` and `-g log` are unprivileged — only the *editing* verbs need
/// sudo, and we never run those.
enum PmsetReader {

    private static let log = FileLog("PmsetReader")
    private static let pmsetPath = "/usr/bin/pmset"

    /// The subset of `pmset -g` keys worth surfacing, in display order.
    private static let interestingKeys = [
        "displaysleep", "sleep", "disksleep", "disablesleep",
        "powernap", "lowpowermode", "hibernatemode", "standby",
        "ttyskeepawake", "womp", "tcpkeepalive",
    ]

    // MARK: - Settings

    static func readSettings() -> [PmsetSetting] {
        guard let out = run(["-g"]) else { return [] }

        // Lines look like:  "  displaysleep         10"
        var parsed: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // First token = key, remainder = value. Skip the header line.
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if parsed[key] == nil { parsed[key] = value }
        }

        // Emit only the interesting keys that are actually present, in our order.
        return interestingKeys.compactMap { key in
            guard let value = parsed[key] else { return nil }
            return PmsetSetting(key: key, value: value)
        }
    }

    // MARK: - Wake / Sleep log

    /// The most recent Sleep/Wake events (newest first), capped to `limit`.
    static func readWakeEvents(limit: Int = 15) -> [WakeEvent] {
        guard let out = run(["-g", "log"]) else { return [] }

        var events: [WakeEvent] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            guard let event = parseLogLine(s) else { continue }
            events.append(event)
        }
        // pmset -g log is oldest-first; we want newest first, capped.
        return Array(events.reversed().prefix(limit))
    }

    /// A pmset log line is columnar:
    /// `2026-06-21 09:15:32 +0800 Wake                  Wake from Standby ... due to ...`
    /// `2026-06-21 02:00:11 +0800 Sleep                 Entering Sleep state due to ...`
    /// `2026-06-21 03:30:00 +0800 DarkWake              DarkWake from Standby ...`
    ///
    /// The event TYPE is a dedicated column — the first whitespace-delimited
    /// field AFTER the `date time tz` timestamp. We match that token exactly so
    /// free-text mentions of "Wake" (e.g. an assertion named "Video Wake Lock"
    /// inside an Assertions summary line) don't masquerade as wake events.
    private static func parseLogLine(_ line: String) -> WakeEvent? {
        // Collapse runs of whitespace, then take token #3 (0-based) as the type:
        // [0]=date [1]=time [2]=tz [3]=type [4...]=message.
        let collapsed = line.replacingOccurrences(of: #"\s{2,}"#, with: " ",
                                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let tokens = collapsed.split(separator: " ").map(String.init)
        guard tokens.count > 3 else { return nil }

        let kind: WakeEvent.Kind
        switch tokens[3] {
        case "DarkWake":         kind = .darkWake
        case "Wake":             kind = .wake
        case "Sleep":            kind = .sleep
        default:                 return nil
        }

        let date = parseLeadingDate(line)

        // Reason = the message column. Prefer the part after "due to" if present
        // (that's the human-meaningful cause); otherwise the whole message.
        var reason: String
        if let r = collapsed.range(of: "due to ") {
            reason = String(collapsed[r.upperBound...])
        } else {
            reason = tokens.count > 4 ? tokens[4...].joined(separator: " ") : ""
        }
        reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim trailing noise pmset appends (e.g. "= 123 secs").
        if let cut = reason.range(of: " = ") { reason = String(reason[..<cut.lowerBound]) }

        return WakeEvent(kind: kind, date: date, reason: reason)
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseLeadingDate(_ line: String) -> Date? {
        // First 25 chars cover "yyyy-MM-dd HH:mm:ss +ZZZZ".
        guard line.count >= 25 else { return nil }
        let stamp = String(line.prefix(25))
        return logDateFormatter.date(from: stamp)
    }

    // MARK: - Process

    private static func run(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pmsetPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // swallow stderr
        do {
            try proc.run()
        } catch {
            log.error("failed to run pmset \(args): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
