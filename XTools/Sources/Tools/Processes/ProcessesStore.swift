import SwiftUI
import Combine
import Darwin

/// UI model for the Process Insight tool.
///
/// Data flow, once per tick:
///
///     identity sweep (in-process sysctl, ~6ms, ALL uids)
///              +
///     metrics sample (`ps` now; a long-lived `top` in the next stage)
///              ↓  join on pid
///     filter → sort → publish  (all of it off the main thread, assigned once)
///
/// The join is re-done from a FRESH roster on every tick rather than reusing the
/// previous one: between two samples a process can die and its pid be handed to
/// something else, and a stale roster would then dress the new process in the old
/// one's name and numbers.
final class ProcessesStore: ObservableObject {

    /// Where the metrics come from. `ps` is both the first-paint seed and the
    /// permanent fallback if the richer source cannot be parsed.
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

    @Published var query: String = "" { didSet { scheduleRecompute() } }
    @Published var sortOrder: [KeyPathComparator<ProcRow>] = [
        .init(\ProcRow.cpuSort, order: .reverse)
    ] { didSet { scheduleRecompute() } }
    @Published var selection: ProcID?

    let prefs: ProcessesPreferences
    let icons = ProcIconCache()

    /// Which memory metric the rows currently carry — drives the column header, so
    /// the number and its name can never disagree.
    var memoryMetric: MemoryMetric { mode == .top ? .footprint : .resident }

    // MARK: Internals

    /// Unfiltered, unsorted rows from the last tick. The source for recomputes that
    /// don't need a new sweep (typing in the search box, clicking a column header).
    private var rawRows: [ProcRow] = []
    private let work = DispatchQueue(label: "me.xueshi.xtools.processes", qos: .userInitiated)
    private var timer: AnyCancellable?
    private var recomputeWork: DispatchWorkItem?
    private var running = false
    private var bag = Set<AnyCancellable>()

    private let log = FileLog("Processes")

    init(prefs: ProcessesPreferences = ProcessesPreferences()) {
        self.prefs = prefs
        // Interval and the system filter both invalidate what's on screen.
        prefs.$hideSystemProcesses
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &bag)
        prefs.$interval
            .dropFirst()
            .sink { [weak self] _ in self?.restartTimerIfRunning() }
            .store(in: &bag)
    }

    // MARK: - Lifecycle
    //
    // Sampling is not free, and this app sits open all day. Nothing samples unless
    // the tool is actually on screen — `start()` / `stop()` are driven by the view's
    // appearance AND by window occlusion, so a window that is minimised or fully
    // covered costs nothing.

    func start() {
        guard !running else { return }
        running = true
        log.info("start (mode=\(self.mode == .ps ? "ps" : "top"), interval=\(self.prefs.interval.seconds)s)")
        refresh()                       // paint immediately, don't wait a full interval
        startTimer()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        log.info("stop")
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: TimeInterval(prefs.interval.seconds), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    private func restartTimerIfRunning() {
        guard running else { return }
        startTimer()
        refresh()
    }

    // MARK: - Sweep

    func refresh() {
        guard !isRefreshing else { return }   // never stack sweeps
        isRefreshing = true

        let hideSystem = prefs.hideSystemProcesses
        let query = self.query
        let sort = self.sortOrder

        work.async { [weak self] in
            let t0 = Date()
            let roster = ProcRoster.snapshot()
            let metrics = PSSampler.sample()
            let joined = Self.join(roster: roster, metrics: metrics)
            let display = Self.display(joined, hideSystem: hideSystem, query: query, sort: sort)
            let ms = Date().timeIntervalSince(t0) * 1000

            DispatchQueue.main.async {
                guard let self else { return }
                self.rawRows = joined
                self.totalCount = joined.count
                self.rows = display
                self.isRefreshing = false
                if self.tickCount % 30 == 0 {   // don't spam the log every few seconds
                    self.log.info("sweep: \(joined.count) processes, \(String(format: "%.0f", ms))ms")
                }
                self.tickCount += 1
            }
        }
    }

    private var tickCount = 0

    /// Attach metrics to identity. A pid present in the roster but missing from the
    /// metrics sample keeps nil metrics and renders as "—" — NOT as 0.
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
}
