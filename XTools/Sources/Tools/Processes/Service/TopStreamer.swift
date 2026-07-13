import Foundation
import Darwin

/// The metrics layer: one long-lived `/usr/bin/top -l 0 -s <interval> -stats
/// pid,cpu,mem,th` child, streamed block by block.
///
/// Why a `top` child at all: it is setuid root, so it reports CPU / `phys_footprint`
/// / thread count for EVERY process — our own libproc calls get EPERM on 100% of
/// other-uid pids (measured 0/206). Its `mem` column equals Activity Monitor's
/// "Memory" column exactly, which is the entire justification for this layer
/// (spec §3, D4). Identity is never scraped from top (its COMMAND column is
/// truncated to 16 chars and can contain spaces) — only the four numeric columns
/// are requested; names come from the in-process roster.
///
/// Failure philosophy (HR7): every failure mode — crash, hang, format drift,
/// sleep/wake weirdness, an unknown unknown — eventually looks like "no complete
/// block arrives" or "a block cannot be trusted". One watchdog plus a stale-block
/// rule therefore covers all of them, and the terminal state is always the same:
/// tell the owner to fall back to the already-working ps mode. Never a blank screen.
///
/// Threading: all state is confined to one serial queue. Events are delivered on
/// that queue; the store re-dispatches.
final class TopStreamer {

    /// One delivered sample block, with the trust policy already applied.
    struct Block {
        let sample: TopSample
        /// False when this block's %CPU must be discarded (MEM/#TH stay valid):
        /// - the child's FIRST block: no delta baseline yet — measured, a process
        ///   burning 100% CPU shows 0.0 / 66.6 / 98.7 across blocks 1/2/3;
        /// - a wall-clock gap > 2×interval since the previous block (sleep/wake,
        ///   SIGSTOP, system stall): the %CPU is a delta spanning the gap.
        ///   Consecutive block timestamps are compared, NOT block-vs-now: after a
        ///   wake the block's own timestamp IS "now", so that test can never fire.
        let cpuValid: Bool
        /// First block since this child was spawned → the owner runs
        /// self-calibration on it (HR4.2). Its MEM is already correct (measured).
        let isFirstAfterSpawn: Bool
    }

    enum Event {
        /// A complete, parsed block.
        case block(Block)
        /// The top pipeline is dead for this app run: 3 consecutive failures, or
        /// an unmappable header. The receiver must fall back to ps mode.
        case failed(reason: String)
    }

    /// Delivered on the streamer's private queue. Set before `start()`.
    var onEvent: ((Event) -> Void)?

    private let q = DispatchQueue(label: "me.xueshi.xtools.processes.top", qos: .userInitiated)
    private let log = FileLog("Processes")

    private var interval: Int
    private var process: Process?
    private var childPid: pid_t = -1
    /// Bumped on every spawn AND every deliberate kill, so pipe/termination
    /// callbacks from a previous child are recognisably stale and ignored.
    private var generation = 0
    private var desiredRunning = false
    private var buffer = ""
    private var stderrTail = ""
    private var blockIndex = 0
    private var lastBlockStamp: Date?     // previous block's preamble wall clock
    private var lastArrival = Date()      // previous block's ARRIVAL (stamp fallback)
    private var lastActivity = Date()     // watchdog baseline: spawn or last block
    private var consecutiveFailures = 0
    private var watchdog: DispatchSourceTimer?

    /// Line-accumulation cap (HR7.4). A healthy block is ~22KB for ~800 processes;
    /// 4MB means parsing has stopped making progress and we resync at a marker.
    private static let maxBufferBytes = 4 << 20
    /// Guard against an unverified long-run leak in the child (HR7.6): top's own
    /// footprint above this triggers a planned restart. Read out of the child's own
    /// row in the sample — costs nothing.
    private static let childMemoryLimit: UInt64 = 200 << 20

    #if DEBUG
    /// Debug-only fallback exercise: `defaults write me.xueshi.xtools.debug
    /// processes.debug.topStats "pid,cpu,mem,notastat"` makes top exit 1 with
    /// `invalid stat:` on stderr (measured — the reliable degradation sentinel).
    /// Compiled out of Release builds entirely.
    private static let debugStatsKey = "processes.debug.topStats"
    #endif

    init(interval: Int) {
        self.interval = interval
    }

    deinit {
        // Last resort — normal paths go through stop(). F14 measured that top also
        // exits by itself within ~2s of losing its reader, but explicit beats implicit.
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    // MARK: - Public control (all thread-safe)

    func start() {
        q.async {
            guard !self.desiredRunning else { return }
            self.desiredRunning = true
            self.consecutiveFailures = 0
            self.spawn()
        }
    }

    /// Deliberate stop (tab hidden, window occluded, app quitting). Kills the
    /// child immediately and cancels the watchdog — a paused streamer must not
    /// accumulate watchdog time, or every pause would look like a hang (HR7.1).
    func stop() {
        q.async {
            guard self.desiredRunning else { return }
            self.desiredRunning = false
            self.stopWatchdog()
            self.killChild()
            self.log.info("top: stopped (deliberate)")
        }
    }

    /// `-l` mode cannot be reconfigured at runtime — an interval change is a
    /// kill + respawn.
    func setInterval(_ seconds: Int) {
        q.async {
            guard self.interval != seconds else { return }
            self.interval = seconds
            guard self.desiredRunning else { return }
            self.log.info("top: interval → \(seconds)s, restarting child")
            self.killChild()
            self.spawn()
        }
    }

    // MARK: - Child lifecycle (queue-confined)

    private func spawn() {
        generation += 1
        let gen = generation
        blockIndex = 0
        lastBlockStamp = nil
        buffer = ""
        stderrTail = ""
        lastActivity = Date()

        var stats = "pid,cpu,mem,th"
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: Self.debugStatsKey), !forced.isEmpty {
            stats = forced
            log.warn("top: DEBUG stats override active: \(forced)")
        }
        #endif

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "0", "-s", String(interval), "-stats", stats]
        // LC_ALL=C: measured unnecessary on macOS 26 (top ignores locale), but the
        // older systems this app supports are unverified and the line is free (HR3).
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LC_NUMERIC"] = "C"
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // stdout as a pipe does NOT block-buffer (measured): each sample block
        // flushes immediately, so the pipeline is event-driven off these reads.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }   // EOF
            self?.q.async { self?.ingest(data, gen: gen) }
        }
        // stderr must be DRAINED, not just piped: a child blocked on a full stderr
        // pipe deadlocks in write() forever (HR7.3). Normally silent; anything it
        // says is diagnostic gold (e.g. `invalid stat:` — the fallback sentinel).
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.q.async {
                guard gen == self.generation else { return }
                let text = String(decoding: data, as: UTF8.self)
                self.stderrTail = String((self.stderrTail + text).suffix(500))
                self.log.error("top stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            self?.q.async { self?.childExited(status: status, gen: gen) }
        }

        do {
            try p.run()
        } catch {
            log.error("top: failed to launch: \(error.localizedDescription)")
            registerFailure("launch failed: \(error.localizedDescription)")
            return
        }
        process = p
        childPid = p.processIdentifier
        log.info("top: spawned pid \(p.processIdentifier) (interval \(self.interval)s, stats \(stats))")
        startWatchdog()
    }

    /// Kill the current child and orphan all of its callbacks. Safe to call with
    /// no child.
    private func killChild() {
        guard let p = process else { return }
        generation += 1
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        // Reap off-queue; also keeps the Process alive until the exit is collected.
        DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
        process = nil
        childPid = -1
        buffer = ""
    }

    private func childExited(status: Int32, gen: Int) {
        guard gen == generation else { return }          // we killed it ourselves
        guard desiredRunning else { return }
        process = nil
        childPid = -1
        // exit 1 + `invalid stat:` on stderr is the measured signature of a -stats
        // keyword the running OS doesn't support — stderrTail carries it into the log.
        let detail = stderrTail.isEmpty ? "" : " — stderr: \(stderrTail)"
        registerFailure("child exited status \(status)\(detail)")
    }

    // MARK: - Ingest

    private func ingest(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        buffer += String(decoding: data, as: UTF8.self)

        if buffer.utf8.count > Self.maxBufferBytes {
            // Parsing has stopped making progress. Resync at the last block marker
            // rather than growing forever (HR7.4).
            if let r = buffer.range(of: "\nProcesses:", options: .backwards) {
                buffer = String(buffer[buffer.index(after: r.lowerBound)...])
            } else {
                buffer = ""
            }
            log.warn("top: accumulation buffer exceeded \(Self.maxBufferBytes >> 20)MB, resynced")
        }

        let result = TopParser.consume(buffer)
        buffer = result.remainder
        if result.headerUnmappable {
            // Format drift: the four columns we asked for cannot be found by name.
            // Nothing downstream can be trusted (HR4.1).
            registerFailure("header unmappable — top's output format has changed")
            return
        }
        for sample in result.samples {
            // A sample can trigger a restart (RSS limit) which invalidates the
            // rest of this batch — they belong to the killed child.
            guard gen == generation else { break }
            handleSample(sample)
        }
    }

    private func handleSample(_ sample: TopSample) {
        guard desiredRunning, process != nil else { return }
        blockIndex += 1
        consecutiveFailures = 0        // a parsed block = the pipeline works
        let arrival = Date()
        lastActivity = arrival

        let isFirst = blockIndex == 1
        var cpuValid = !isFirst
        // Stale-block rejection (HR7.2): consecutive block TIMESTAMPS, gap beyond
        // 2×interval → this block's %CPU is a delta spanning the gap. Its MEM/#TH
        // are point-in-time and stay valid.
        if cpuValid {
            let gap: TimeInterval?
            if let ts = sample.timestamp, let prev = lastBlockStamp {
                gap = ts.timeIntervalSince(prev)
            } else {
                gap = arrival.timeIntervalSince(lastArrival)   // no stamp: arrival approximates it
            }
            if let g = gap, g > Double(2 * interval) {
                cpuValid = false
                log.info("top: stale block (gap \(Int(g))s > \(2 * self.interval)s) — CPU discarded, memory/threads kept")
            }
        }
        if let ts = sample.timestamp { lastBlockStamp = ts }
        lastArrival = arrival

        if sample.droppedRows > 0 {
            log.warn("top: block \(self.blockIndex) dropped \(sample.droppedRows) unparseable rows")
        }

        // The sample conveniently includes the child itself — a free RSS gauge for
        // the long-run-leak guard (HR7.6).
        if let ownMem = sample.rows[childPid]?.memoryBytes, ownMem > Self.childMemoryLimit {
            log.warn("top: child footprint \(ownMem >> 20)MB over \(Self.childMemoryLimit >> 20)MB — planned restart")
            onEvent?(.block(Block(sample: sample, cpuValid: cpuValid, isFirstAfterSpawn: isFirst)))
            killChild()
            spawn()
            return
        }

        onEvent?(.block(Block(sample: sample, cpuValid: cpuValid, isFirstAfterSpawn: isFirst)))
    }

    // MARK: - Watchdog (HR7.1)

    private func startWatchdog() {
        stopWatchdog()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard desiredRunning, process != nil else { return }
        let silent = Date().timeIntervalSince(lastActivity)
        if silent > Double(3 * interval) {
            registerFailure("watchdog: no complete block for \(Int(silent))s (limit \(3 * interval)s)")
        }
    }

    // MARK: - Failure accounting

    /// Kill, count, and either respawn with exponential backoff or — after 3
    /// consecutive failures — declare the pipeline dead so the owner falls back
    /// to ps mode. Any successfully parsed block resets the count.
    private func registerFailure(_ reason: String) {
        killChild()
        consecutiveFailures += 1
        log.error("top: failure #\(self.consecutiveFailures): \(reason)")

        if consecutiveFailures >= 3 {
            desiredRunning = false
            stopWatchdog()
            onEvent?(.failed(reason: reason))
            return
        }
        let delay = pow(2.0, Double(consecutiveFailures - 1))   // 1s, 2s
        let gen = generation
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.desiredRunning, gen == self.generation else { return }
            self.spawn()
        }
    }
}
