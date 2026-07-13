import Foundation

/// Disk cache of AI explanations, keyed by a hash of the payload.
///
/// **What goes on disk: the SHA-256 of the payload, and the answer. Never the
/// payload itself.** That is the whole reason a disk cache is acceptable here — a
/// hash is irreversible, so no argv, no path, no username, no bundle id is written
/// anywhere. What we get in return is real: reopen the tool tomorrow, click the
/// same process, and it costs nothing.
///
/// Residual risk, stated rather than hidden: the ANSWER is free text and could in
/// principle quote something back from the payload. It is a natural-language
/// explanation of a process, and the payload it came from was already redacted
/// before it was ever sent — but the user can wipe the cache from the tool, and
/// that button exists for exactly this reason.
final class ExplanationCache {

    private struct Entry: Codable {
        let answer: String
        /// Seconds since epoch. Only used to evict the oldest — not shown anywhere.
        var lastUsed: Double
    }

    private let limit = 200
    private let queue = DispatchQueue(label: "me.xueshi.xtools.processes.aicache")
    private var entries: [String: Entry] = [:]
    private let url: URL
    private let log = FileLog("Processes")

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("processes-ai-cache.json")
        // Off the caller's thread: the instance is created on main (store init),
        // and a disk read does not belong there. The serial queue orders this
        // load before any `answer(for:)` lookup.
        queue.async { [weak self] in self?.load() }
    }

    // MARK: - API

    func answer(for key: String) -> String? {
        queue.sync {
            guard var e = entries[key] else { return nil }
            e.lastUsed = Date().timeIntervalSince1970
            entries[key] = e
            return e.answer
        }
    }

    func store(_ answer: String, for key: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.entries[key] = Entry(answer: answer, lastUsed: Date().timeIntervalSince1970)
            if self.entries.count > self.limit {
                // Evict least-recently-used down to the limit.
                let ordered = self.entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                for (k, _) in ordered.prefix(self.entries.count - self.limit) {
                    self.entries.removeValue(forKey: k)
                }
            }
            self.persist()
        }
    }

    var count: Int { queue.sync { entries.count } }

    /// The user's escape hatch. Wipes the file too, not just memory.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.removeAll()
            try? FileManager.default.removeItem(at: self.url)
            self.log.info("AI cache cleared")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        // A corrupt or future-format file must never crash the tool or lose the
        // user anything that matters — this is a cache; start empty.
        guard let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            log.warn("AI cache unreadable — starting empty")
            return
        }
        entries = decoded
    }

    /// Called on `queue`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.warn("AI cache write failed: \(error.localizedDescription)")
        }
    }
}
