import Foundation

/// Metrics for one process, parsed out of one `top` sample block.
///
/// All optional: a field that fails to parse becomes nil (rendered "—"), it never
/// becomes 0 — a fake 0 is indistinguishable from a genuinely idle process.
struct TopRowMetrics: Equatable {
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var threadCount: Int?
}

/// One complete sample block from `top -l 0`.
struct TopSample {
    /// Wall-clock timestamp from the block's preamble (measured present, line 2:
    /// `2026/07/12 17:36:36`). Consecutive-block gaps detect sleep/wake stalls.
    var timestamp: Date?
    /// `Processes: N total, …` from the preamble's first line.
    var declaredCount: Int?
    var rows: [pid_t: TopRowMetrics] = [:]
    /// Data lines that could not be parsed at all (bad pid / wrong field count).
    var droppedRows = 0
}

/// Parser for `top -l 0 -s <n> -stats pid,cpu,mem,th` output. PURE functions over
/// text — no process handling, no state, so it can be fed captured samples.
///
/// Why the shape of this parser is the way it is (every rule below was measured,
/// not guessed — spec §2):
///
/// - `top` has NO structured output. Each sample block is: a `Processes:` preamble,
///   a blank line, a `PID  %CPU  MEM  #TH` header, then one row per process.
/// - Columns are mapped BY HEADER NAME, never by fixed position (HR4.1): if a
///   future macOS reorders or renames columns this degrades to the ps fallback
///   instead of silently swapping CPU with MEM.
/// - MEM values carry `+`/`-` delta markers from the second block onward (~5% of
///   rows in a 13s capture: `M+`×108, `M-`×77, `K+`×68, `K-`×21). A parser that
///   only accepts `K`/`M` drops those rows.
/// - `#TH` can be `957/19` (total/running) — take the part before the slash.
/// - Numbers are parsed with POSIX semantics (`Double(String)`), NEVER a
///   locale-following `NumberFormatter` (HR3) — a decimal comma would silently
///   zero the columns.
/// - The declared count (`Processes: 745 total`) matched the row count exactly in
///   every measured block, which gives a deterministic completeness rule for a
///   block that is still streaming in: header seen + declared rows received.
enum TopParser {

    /// Result of consuming an accumulation buffer: every block that is complete,
    /// plus the tail that is still growing (feed it back as the next buffer's
    /// prefix).
    struct StreamResult {
        var samples: [TopSample] = []
        var remainder = ""
        /// A COMPLETE block arrived whose header could not be mapped by name —
        /// the format has drifted and nothing downstream can be trusted. The
        /// caller must treat this as a failure of the top pipeline (HR4.1).
        var headerUnmappable = false
    }

    /// The column names this build requests via `-stats pid,cpu,mem,th`. All four
    /// must be present in the header, by name, or the block is unusable.
    private static let requiredColumns = ["PID", "%CPU", "MEM", "#TH"]

    static func consume(_ text: String) -> StreamResult {
        var result = StreamResult()
        guard !text.isEmpty else { return result }

        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline { lines.removeLast() }   // drop the empty trailing component
        let lastLineIsPartial = !endsWithNewline

        // Group lines into segments, each starting at a "Processes:" preamble line.
        // Text before the first marker is unparseable junk and is dropped — this is
        // also the resync rule after a buffer overflow.
        var closed: [[String]] = []      // segments known complete (a next marker followed)
        var current: [String] = []
        var sawMarker = false
        for (i, line) in lines.enumerated() {
            let isPartial = lastLineIsPartial && i == lines.count - 1
            if line.hasPrefix("Processes:") && !isPartial {
                if sawMarker { closed.append(current) }
                current = [line]
                sawMarker = true
            } else if sawMarker {
                current.append(line)
            }
        }

        guard sawMarker else {
            // No block started yet. Keep only a partial tail — it may still grow
            // into a "Processes:" line; anything terminated is junk.
            if lastLineIsPartial, let tail = lines.last { result.remainder = tail }
            return result
        }

        for segment in closed {
            let block = parseSegment(segment, mayGrow: false)
            if block.headerBad { result.headerUnmappable = true }
            else if let sample = block.sample { result.samples.append(sample) }
        }

        // The trailing segment may still be streaming in. It is complete iff the
        // declared row count has fully arrived (only terminated lines count).
        var tail = current
        if lastLineIsPartial { tail.removeLast() }
        let block = parseSegment(tail, mayGrow: true)
        if block.headerBad {
            result.headerUnmappable = true
        } else if block.isComplete, let sample = block.sample {
            result.samples.append(sample)
            // Bytes past the declared row count already belong to the NEXT block
            // (typically the partial beginnings of its "Processes:" line) — they
            // must survive as the remainder, not vanish with this block.
            var leftover = Array(tail.dropFirst(block.consumedLines))
            if lastLineIsPartial, let partial = current.last { leftover.append(partial) }
            result.remainder = leftover.isEmpty ? "" :
                leftover.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        } else {
            result.remainder = current.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        }
        return result
    }

    // MARK: - One segment

    private struct ParsedBlock {
        var sample: TopSample?
        var isComplete = false
        var headerBad = false
        /// How many of the segment's lines this block used up. Only meaningful
        /// when a growing tail completes by row count — lines after this index
        /// belong to the next block.
        var consumedLines = 0
    }

    /// `mayGrow`: the segment is the buffer's tail and more lines may follow — an
    /// unmappable-so-far header or a short row count mean "wait", not "broken".
    private static func parseSegment(_ lines: [String], mayGrow: Bool) -> ParsedBlock {
        var block = ParsedBlock()
        guard let first = lines.first, first.hasPrefix("Processes:") else {
            // A closed segment must start at a marker (the grouping guarantees it);
            // anything else is a logic-level impossibility — treat as unusable.
            block.headerBad = !mayGrow
            return block
        }

        var sample = TopSample()
        sample.declaredCount = declaredCount(in: first)

        // Preamble: everything until the header line. Pick the timestamp out of it.
        var columnIndex: [String: Int] = [:]
        var columnCount = 0
        var headerLine = -1
        for (i, line) in lines.enumerated().dropFirst() {
            if sample.timestamp == nil, let ts = timestamp(from: line) {
                sample.timestamp = ts
                continue
            }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if tokens.contains("PID") {
                for (idx, name) in tokens.enumerated() { columnIndex[name] = idx }
                columnCount = tokens.count
                headerLine = i
                break
            }
        }

        guard headerLine >= 0 else {
            // No header yet. For a closed block that IS format drift; for a growing
            // tail it just hasn't arrived.
            block.headerBad = !mayGrow
            return block
        }
        for required in requiredColumns where columnIndex[required] == nil {
            block.headerBad = true
            return block
        }
        let pidIdx = columnIndex["PID"]!
        let cpuIdx = columnIndex["%CPU"]!
        let memIdx = columnIndex["MEM"]!
        let thIdx  = columnIndex["#TH"]!

        var dataLines = 0
        var consumed = lines.count
        for (i, line) in lines.enumerated().dropFirst(headerLine + 1) {
            if line.isEmpty { continue }
            dataLines += 1
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // By-name mapping only holds if the row has exactly the header's column
            // count — more or fewer means a column we don't understand appeared.
            if fields.count == columnCount, let pid = pid_t(fields[pidIdx]) {
                sample.rows[pid] = TopRowMetrics(
                    cpuPercent: Double(fields[cpuIdx]),
                    memoryBytes: parseMemory(String(fields[memIdx])),
                    threadCount: parseThreads(String(fields[thIdx]))
                )
            } else {
                sample.droppedRows += 1
            }
            if mayGrow, let declared = sample.declaredCount, dataLines >= declared {
                consumed = i + 1
                break
            }
        }

        block.sample = sample
        block.consumedLines = consumed
        block.isComplete = !mayGrow
            || (sample.declaredCount.map { dataLines >= $0 } ?? false)
        return block
    }

    // MARK: - Field parsers (each measured against real output)

    /// `284M`, `957K+`, `1168K-`, defensively `0B`/`3G` and a bare byte count.
    /// The trailing `+`/`-` is top's grew/shrank marker, present from block 2 on.
    static func parseMemory(_ raw: String) -> UInt64? {
        var s = Substring(raw)
        if s.hasSuffix("+") || s.hasSuffix("-") { s = s.dropLast() }
        guard let last = s.last else { return nil }
        let multiplier: Double
        switch last {
        case "B": multiplier = 1;                        s = s.dropLast()
        case "K": multiplier = 1024;                     s = s.dropLast()
        case "M": multiplier = 1024 * 1024;              s = s.dropLast()
        case "G": multiplier = 1024 * 1024 * 1024;       s = s.dropLast()
        default:  multiplier = 1   // bare number: unobserved, accepted defensively
        }
        // POSIX parse — `Double("2,5")` correctly fails rather than following locale.
        guard let value = Double(s), value >= 0, value.isFinite else { return nil }
        return UInt64(value * multiplier)
    }

    /// `23`, or `957/19` (total/running — take the total).
    static func parseThreads(_ raw: String) -> Int? {
        guard let first = raw.split(separator: "/").first else { return nil }
        return Int(first)
    }

    /// First integer of `Processes: 745 total, 5 running, …`.
    private static func declaredCount(in line: String) -> Int? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }
        return Int(tokens[1])
    }

    // MARK: - Timestamp

    /// `2026/07/12 17:36:36` — the only all-digit `Y/M/D H:M:S` line the preamble
    /// contains (measured). Parsed with a POSIX-locale formatter.
    static func timestamp(from line: String) -> Date? {
        guard line.count == 19, line.first?.isNumber == true else { return nil }
        return formatter.date(from: line)
    }

    /// DateFormatter is not thread-safe under concurrent use; the streamer calls
    /// the parser from a single serial queue, which is the supported usage here.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
