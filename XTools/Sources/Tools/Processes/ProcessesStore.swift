import SwiftUI
import AppKit
import Combine
import Darwin

/// UI model for the Process Insight tool.
///
/// Data flow, once per update:
///
///     identity sweep (in-process sysctl, ~6ms, ALL uids)
///              +
///     metrics table (long-lived `top` child; `ps` as seed and fallback)
///              ↓  join on pid
///     filter → sort → publish  (all of it off the main thread, assigned once)
///
/// Two update cadences coexist:
/// - **top mode** is EVENT-DRIVEN: a block arrives (~interval + sampling time,
///   measured ~2.19s at `-s 2`) → fresh identity sweep → join → publish. No
///   timer — top's delivery drifts, so an absolute schedule would tear.
/// - **ps mode** (fallback) polls `PSSampler` on a timer, exactly as before.
///
/// The join is re-done from a FRESH roster on every update rather than reusing
/// the previous one (HR8.1): between two samples a process can die and its pid be
/// handed to something else, and a stale roster would then dress the new process
/// in the old one's name and numbers.
///
/// Lifecycle (HR5): the metrics pipeline runs ONLY while the tab is selected AND
/// the window is actually visible. This window sits open all day — a "selected
/// but unwatched" tab must not keep a top child burning 3–7% of a core forever.
final class ProcessesStore: ObservableObject {

    /// Where the metrics come from. `ps` is both the first-paint seed and the
    /// permanent fallback if `top` cannot be launched, parsed, or calibrated.
    enum Mode: Equatable {
        case ps
        case top
    }

    // MARK: Published state

    /// Display rows: filtered and sorted, ready to render.
    @Published private(set) var rows: [ProcRow] = []
    /// Total processes seen this tick, before the filter (for the status line).
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var mode: Mode = .ps
    @Published private(set) var isRefreshing = false
    @Published var actionMessage: String?
    /// A destructive action waiting for the user's confirmation (§7: Force Quit
    /// always confirms; any non-own-uid signal confirms; own Quit is a graceful
    /// ask and goes straight through). Holds a ROW SNAPSHOT — the fingerprint
    /// gate in `ProcActions` re-verifies it against the live pid on confirm.
    @Published var pendingAction: PendingProcAction?

    @Published var query: String = "" { didSet { scheduleRecompute() } }
    @Published var sortOrder: [KeyPathComparator<ProcRow>] = [
        .init(\ProcRow.cpuSort, order: .reverse)
    ] { didSet { scheduleRecompute() } }
    @Published var selection: ProcID? {
        didSet {
            guard oldValue != selection else { return }
            explainer.select(selectedRow)
            rebuildFacts()
        }
    }

    /// Deterministic facts for the selected process (signature, launchd label,
    /// argv, parent chain). Built off the main thread when the selection moves —
    /// a code-signature check on a big bundle can take seconds — and nil while
    /// still being computed.
    @Published private(set) var facts: ProcFacts?

    let prefs: ProcessesPreferences
    let icons = ProcIconCache()
    /// The AI half of the detail pane. Owns the payload gate, the stream and the cache.
    let explainer: ProcExplainer

    /// Which memory metric the rows currently carry — drives the column header, so
    /// the number and its name can never disagree.
    var memoryMetric: MemoryMetric { mode == .top ? .footprint : .resident }

    // MARK: Internals

    /// Unfiltered, unsorted rows from the last update. The source for recomputes
    /// that don't need a new sweep (typing in the search box, sorting).
    private var rawRows: [ProcRow] = []
    private let work = DispatchQueue(label: "me.xueshi.xtools.processes", qos: .userInitiated)
    /// Separate queue for facts: a slow signature check (seconds on a big
    /// Electron bundle) must never delay the next metrics sweep.
    private let factsWork = DispatchQueue(label: "me.xueshi.xtools.processes.facts", qos: .userInitiated)
    private var factsGeneration = 0
    private var timer: AnyCancellable?
    private var recomputeWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    /// Current metrics keyed by pid — whichever source last produced them.
    /// Confined to the `work` queue.
    private var metricsByPid: [pid_t: ProcMetrics] = [:]

    /// The long-lived top child, when top mode is up. Main-thread confined.
    private var streamer: TopStreamer?
    /// Set once top has terminally failed (3 consecutive failures, format drift,
    /// or self-calibration mismatch). ps mode for the rest of this app run; a
    /// fresh launch retries top.
    private var topDisabled = false

    // Visibility inputs (HR5). All main-thread. The pipeline runs only while
    // EVERY one of these is true.
    private var viewVisible = false            // tab selected + view in hierarchy
    private var windowVisible = true           // occlusionState contains .visible
    private var sessionActive = true           // fast user switching
    private var screensAwake = true            // display sleep / system sleep
    private var pipelineRunning = false

    private weak var hostWindow: NSWindow?
    private var occlusionObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    private let log = FileLog("Processes")

    init(llm: LLMService, prefs: ProcessesPreferences = ProcessesPreferences()) {
        self.prefs = prefs
        self.explainer = ProcExplainer(llm: llm, prefs: prefs)
        // Interval and the system filter both invalidate what's on screen.
        // `.receive(on:)` matters: @Published emits during willSet, so a handler
        // that runs synchronously would still read the OLD value off `prefs`.
        // Hopping to the next main-queue turn lets the property settle first.
        prefs.$hideSystemProcesses
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &bag)
        prefs.$interval
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.intervalChanged() }
            .store(in: &bag)
        observeWorkspace()
    }

    deinit {
        if let token = occlusionObserver { NotificationCenter.default.removeObserver(token) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        streamer?.stop()
    }

    // MARK: - Lifecycle (HR5)
    //
    // Sampling is not free, and this app sits open all day. The pipeline runs only
    // while someone can actually SEE the page: tab selected (view appear/disappear)
    // AND window unoccluded (not minimised, not fully covered, not on another
    // Space, screen awake) AND the login session active (fast user switching).
    // Any of these dropping kills the top child immediately; restoring respawns it
    // (first block ~1.2s; a ps seed covers the gap).

    func start() {
        viewVisible = true
        reevaluatePipeline("view appeared")
    }

    func stop() {
        viewVisible = false
        reevaluatePipeline("view disappeared")
    }

    /// Called by the view when it lands in (or leaves) an NSWindow, so occlusion
    /// can be tracked. `onAppear`/`onDisappear` alone cannot see a minimised or
    /// covered window — the view stays "appeared" the whole time.
    func attach(window newWindow: NSWindow?) {
        guard newWindow !== hostWindow else { return }
        if let token = occlusionObserver {
            NotificationCenter.default.removeObserver(token)
            occlusionObserver = nil
        }
        hostWindow = newWindow
        guard let window = newWindow else { return }   // view left; stop() handles it
        windowVisible = window.occlusionState.contains(.visible)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            let visible = w.occlusionState.contains(.visible)
            guard visible != self.windowVisible else { return }
            self.windowVisible = visible
            self.reevaluatePipeline(visible ? "window visible" : "window occluded")
        }
        reevaluatePipeline("window attached")
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ change: @escaping (ProcessesStore) -> Void, _ why: String) {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                change(self)
                self.reevaluatePipeline(why)
            })
        }
        // Fast user switching: our session keeps running, but nobody is looking.
        on(NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }, "session resigned")
        on(NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }, "session active")
        // Display sleep, and system sleep (which implies it). Occlusion does not
        // reliably change when only the screen goes dark, so this is explicit.
        on(NSWorkspace.screensDidSleepNotification, { $0.screensAwake = false }, "screens slept")
        on(NSWorkspace.screensDidWakeNotification, { $0.screensAwake = true }, "screens woke")
        on(NSWorkspace.willSleepNotification, { $0.screensAwake = false }, "system sleeping")
        on(NSWorkspace.didWakeNotification, { $0.screensAwake = true }, "system woke")
    }

    private func reevaluatePipeline(_ reason: String) {
        let shouldRun = viewVisible && windowVisible && sessionActive && screensAwake
        guard shouldRun != pipelineRunning else { return }
        pipelineRunning = shouldRun
        if shouldRun {
            log.info("pipeline start (\(reason), source=\(self.topDisabled ? "ps" : "top"), interval=\(self.prefs.interval.seconds)s)")
            seedRefresh()               // paint immediately, don't wait for a block
            if topDisabled {
                startTimer()
            } else {
                startStreamer()
            }
        } else {
            log.info("pipeline stop (\(reason))")
            timer?.cancel()
            timer = nil
            streamer?.stop()            // kills the top child immediately
            streamer = nil
        }
    }

    private func intervalChanged() {
        guard pipelineRunning else { return }
        if let streamer {
            streamer.setInterval(prefs.interval.seconds)   // kill + respawn; -l can't be reconfigured
        } else {
            startTimer()
            psTick()
        }
    }

    // MARK: - top pipeline

    private func startStreamer() {
        let s = TopStreamer(interval: prefs.interval.seconds)
        // Events hop to the main thread first: mode/state decisions are cheap and
        // main-confined; the heavy sweep+join is then dispatched to `work`.
        s.onEvent = { [weak self, weak s] event in
            DispatchQueue.main.async {
                guard let self, let s, self.streamer === s else { return }   // stale child
                switch event {
                case .failed(let reason):
                    self.fallBackToPS(reason: reason)
                case .block(let block):
                    self.applyTopBlock(block)
                }
            }
        }
        streamer = s
        s.start()
    }

    /// Terminal degradation (HR4/§7): kill the top pipeline for the rest of this
    /// run and poll ps instead. The memory column header and the status-bar note
    /// follow `mode` automatically. Never a blank screen — the rows keep flowing,
    /// only the memory metric changes (and says so).
    private func fallBackToPS(reason: String) {
        guard !topDisabled else { return }
        topDisabled = true
        streamer?.stop()
        streamer = nil
        mode = .ps
        log.error("metrics degraded to ps mode: \(reason)")
        if pipelineRunning {
            startTimer()
            psTick()
        }
    }

    /// One top block: merge metrics, re-sweep identity, join, publish. First block
    /// of a child also runs self-calibration (HR4.2).
    private func applyTopBlock(_ block: TopStreamer.Block) {
        let ctx = displayContext()
        work.async { [weak self] in
            guard let self else { return }
            let sample = block.sample

            var table: [pid_t: ProcMetrics] = [:]
            table.reserveCapacity(sample.rows.count)
            for (pid, m) in sample.rows {
                table[pid] = ProcMetrics(
                    // An invalid CPU (first block's no-baseline zeros, or a delta
                    // spanning a sleep) keeps the previous value — the ps seed at
                    // start, or the prior block — and recovers next block.
                    cpuPercent: block.cpuValid ? m.cpuPercent : self.metricsByPid[pid]?.cpuPercent,
                    memoryBytes: m.memoryBytes,
                    threadCount: m.threadCount
                )
            }

            // Fresh identity sweep on EVERY block (HR8.1) — never a stale roster.
            let roster = ProcRoster.snapshot()

            if block.isFirstAfterSpawn {
                let outcome = SelfCalibration.check(sample: sample, rosterCount: roster.count)
                self.log.info("self-calibration \(outcome.passed ? "OK" : "FAILED"): \(outcome.summary)")
                if !outcome.passed {
                    // Do not publish numbers that just failed their own audit.
                    DispatchQueue.main.async {
                        self.fallBackToPS(reason: "self-calibration failed: \(outcome.summary)")
                    }
                    return
                }
            }

            self.metricsByPid = table
            self.joinAndPublish(roster: roster, ctx: ctx, becomeTop: true)
        }
    }

    // MARK: - ps pipeline (seed + fallback)

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: TimeInterval(prefs.interval.seconds), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.psTick() }
    }

    /// One ps poll: the whole metrics table is replaced. Fallback mode's cadence.
    private func psTick() {
        let ctx = displayContext()
        work.async { [weak self] in
            guard let self else { return }
            let metrics = PSSampler.sample()
            // On a failed sample keep the previous table rather than blanking every row.
            if !metrics.isEmpty { self.metricsByPid = metrics }
            self.joinAndPublish(roster: ProcRoster.snapshot(), ctx: ctx, becomeTop: false)
        }
    }

    /// One `ps` sample at pipeline start, so the page paints instantly instead of
    /// waiting ~1.2s for top's first block — and top's first block has no usable
    /// CPU anyway (no delta baseline), so this seed is what the CPU column shows
    /// until block 2.
    private func seedRefresh() {
        let ctx = displayContext()
        let fillMemory = (mode == .ps)   // read on main
        work.async { [weak self] in
            guard let self else { return }
            let seed = PSSampler.sample()
            if !seed.isEmpty {
                if fillMemory {
                    self.metricsByPid = seed
                } else {
                    // Resuming while the table holds footprints: ps's rss is a
                    // DIFFERENT metric than the header now promises, so only the
                    // CPU may cross over. Memory/threads keep their last top
                    // values (~pause-old, refreshed by the next block).
                    var table: [pid_t: ProcMetrics] = [:]
                    table.reserveCapacity(seed.count)
                    for (pid, m) in seed {
                        var entry = self.metricsByPid[pid] ?? ProcMetrics()
                        entry.cpuPercent = m.cpuPercent
                        table[pid] = entry
                    }
                    self.metricsByPid = table
                }
            }
            self.joinAndPublish(roster: ProcRoster.snapshot(), ctx: ctx, becomeTop: false)
        }
    }

    // MARK: - Join + publish (work queue)

    /// Filter/sort inputs, captured on the main thread before hopping queues.
    private struct DisplayContext {
        let hideSystem: Bool
        let query: String
        let sort: [KeyPathComparator<ProcRow>]
    }

    private func displayContext() -> DisplayContext {
        DisplayContext(hideSystem: prefs.hideSystemProcesses, query: query, sort: sortOrder)
    }

    /// On the `work` queue: join the roster against the current metrics table,
    /// filter + sort, and hand the finished arrays to the main thread in one
    /// assignment. `becomeTop` flips the mode (and with it the memory column
    /// header) in the SAME main-thread turn that publishes footprint numbers, so
    /// the header and the numbers can never disagree.
    private func joinAndPublish(roster: [ProcRow], ctx: DisplayContext, becomeTop: Bool) {
        let t0 = Date()
        let joined = Self.join(roster: roster, metrics: metricsByPid)
        let display = Self.display(joined, hideSystem: ctx.hideSystem, query: ctx.query, sort: ctx.sort)
        let ms = Date().timeIntervalSince(t0) * 1000

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if becomeTop && !self.topDisabled && self.mode != .top {
                self.mode = .top
                self.log.info("mode → top (memory column is now phys_footprint)")
            }
            self.rawRows = joined
            self.totalCount = joined.count
            self.rows = display
            self.isRefreshing = false
            if self.tickCount % 30 == 0 {   // don't spam the log every few seconds
                self.log.info("update: \(joined.count) processes, \(String(format: "%.0f", ms))ms (\(self.mode == .top ? "top" : "ps"))")
            }
            self.tickCount += 1
            self.refreshFactsRow()
        }
    }

    private var tickCount = 0

    /// Attach metrics to identity. Only pids present in BOTH render numbers; a
    /// pid in the roster but missing from the metrics table keeps nil metrics and
    /// renders as "—" — NOT as 0.
    private static func join(roster: [ProcRow], metrics: [pid_t: ProcMetrics]) -> [ProcRow] {
        roster.map { row in
            guard let m = metrics[row.pid] else { return row }
            var r = row
            r.cpuPercent = m.cpuPercent
            r.memoryBytes = m.memoryBytes
            r.threadCount = m.threadCount
            return r
        }
    }

    // MARK: - Manual refresh (toolbar button)

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if streamer != nil && !topDisabled {
            // Top mode is event-driven; a manual refresh re-sweeps identity and
            // rejoins so new/died processes show immediately. Metrics follow with
            // the next block.
            let ctx = displayContext()
            work.async { [weak self] in
                guard let self else { return }
                self.joinAndPublish(roster: ProcRoster.snapshot(), ctx: ctx, becomeTop: false)
            }
        } else {
            psTick()
        }
    }

    // MARK: - Filter + sort (background)

    private static func display(_ all: [ProcRow],
                                hideSystem: Bool,
                                query: String,
                                sort: [KeyPathComparator<ProcRow>]) -> [ProcRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out = all.filter { row in
            // The search box wins over the system filter: if you explicitly search
            // for "logd", you want to find it even with system processes hidden.
            if hideSystem && q.isEmpty && row.isAppleSystem { return false }
            guard !q.isEmpty else { return true }
            if q.allSatisfy(\.isNumber), String(row.pid) == q { return true }
            return row.name.lowercased().contains(q)
                || String(row.pid).contains(q)
                || (row.executablePath?.lowercased().contains(q) ?? false)
        }
        out.sort(using: sort)
        return out
    }

    /// Debounced recompute from the cached rows — no syscalls, no `ps`. Typing in
    /// the search field must not trigger a process sweep per keystroke.
    private func scheduleRecompute() {
        recomputeWork?.cancel()
        let hideSystem = prefs.hideSystemProcesses
        let query = self.query
        let sort = self.sortOrder
        let all = rawRows
        let item = DispatchWorkItem { [weak self] in
            let display = Self.display(all, hideSystem: hideSystem, query: query, sort: sort)
            DispatchQueue.main.async { self?.rows = display }
        }
        recomputeWork = item
        work.asyncAfter(deadline: .now() + 0.15, execute: item)   // 150ms debounce
    }

    // MARK: - Selection helper

    var selectedRow: ProcRow? {
        guard let sel = selection else { return nil }
        return rawRows.first { $0.id == sel }
    }

    /// Row lookup for the table's context menu (right-click passes the row id).
    func row(for id: ProcID) -> ProcRow? {
        rawRows.first { $0.id == id }
    }

    // MARK: - Actions (Quit / Force Quit / Reveal / Copy — §7)

    /// Quit: own processes are asked politely with no confirmation (a graceful
    /// quit is what the ⌘Q every app already has does); a root / other-uid quit
    /// costs an admin password and IS confirmed first.
    func requestQuit(_ row: ProcRow) {
        guard row.canTerminate else { return }
        if row.isCurrentUser {
            runAction(.quit, on: row)
        } else {
            pendingAction = PendingProcAction(kind: .quit, row: row)
        }
    }

    /// Force Quit: always confirmed — SIGKILL gives the process no chance to
    /// save anything.
    func requestForceQuit(_ row: ProcRow) {
        guard row.canTerminate else { return }
        pendingAction = PendingProcAction(kind: .forceQuit, row: row)
    }

    /// The confirmation dialog's destructive button.
    func confirmPendingAction() {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        runAction(pending.kind, on: pending.row)
    }

    /// Off the main thread: the privileged path blocks on the password prompt,
    /// and even the own-process path does syscalls we don't want on main.
    private func runAction(_ kind: ProcActions.Kind, on row: ProcRow) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ProcActions.perform(kind, on: row)
            DispatchQueue.main.async {
                guard let self else { return }
                self.actionMessage = outcome.message
                self.refresh()
                // A graceful quit takes a moment; refresh again so the row's
                // disappearance is visible without waiting a full interval.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    func revealInFinder(_ row: ProcRow) {
        ProcActions.revealInFinder(row)
    }

    func copyPath(_ row: ProcRow) {
        if ProcActions.copyPath(row) {
            actionMessage = L("processes.action.copied")
        }
    }

    // MARK: - App termination

    /// Explicit child kill on app exit (HR7.5). Measured: top exits by itself
    /// within ~2s of losing its reader — but explicit beats relying on SIGPIPE.
    func shutdown() {
        streamer?.stop()
        streamer = nil
        timer?.cancel()
        timer = nil
    }

    // MARK: - Facts for the selected process

    /// Kick off a facts build for the current selection. Generation-guarded:
    /// selecting three rows quickly must apply only the LAST build, not
    /// whichever slow signature check finishes last.
    private func rebuildFacts() {
        factsGeneration += 1
        let gen = factsGeneration
        facts = nil
        guard let row = selectedRow else { return }
        let roster = rawRows
        factsWork.async { [weak self] in
            let built = ProcFactsBuilder.build(for: row, roster: roster)
            DispatchQueue.main.async {
                guard let self, gen == self.factsGeneration else { return }
                self.facts = built
                self.explainer.setFacts(built, metric: self.memoryMetric)
            }
        }
    }

    /// After every update, refresh the metrics inside the published facts so the
    /// detail pane and the payload preview carry current numbers — WITHOUT
    /// re-running the expensive signature/launchd work (those don't change).
    private func refreshFactsRow() {
        guard let current = facts, let row = selectedRow, row.id == current.row.id,
              row != current.row else { return }
        let updated = current.updating(row: row)
        facts = updated
        explainer.setFacts(updated, metric: memoryMetric)
    }
}

/// A destructive action the user has clicked but not yet confirmed. Carries the
/// row SNAPSHOT the user was looking at; the fingerprint gate re-verifies it at
/// confirm time, so a pid that died (or was recycled) while this dialog sat open
/// is refused, not killed.
struct PendingProcAction: Identifiable {
    let id = UUID()
    let kind: ProcActions.Kind
    let row: ProcRow

    var title: String {
        String(format: L(kind == .quit ? "processes.action.confirm.quit.title"
                                       : "processes.action.confirm.forceQuit.title"),
               row.name)
    }

    var message: String {
        let owner = ProcessListView.userName(uid: row.uid)
        if row.isCurrentUser {
            return L("processes.action.confirm.forceQuit.own")   // own+quit never confirms
        }
        return String(format: L(kind == .quit ? "processes.action.confirm.quit.root"
                                              : "processes.action.confirm.forceQuit.root"),
                      owner)
    }

    var confirmTitle: String {
        L(kind == .quit ? "processes.action.quit" : "processes.action.forceQuit")
    }
}
