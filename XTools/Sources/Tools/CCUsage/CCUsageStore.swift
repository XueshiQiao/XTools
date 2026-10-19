import SwiftUI
import AppKit
import Combine

/// State and refresh lifecycle for the CCUsage tool.
///
/// Auto-refresh runs only while the tab is selected AND the window is visible,
/// matching the power-saving pattern in `ProcessesStore`.
final class CCUsageStore: ObservableObject {

    @Published private(set) var report: CCUsageReport = .empty
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    /// Which day period (`YYYY-MM-DD`) is currently focused for the Agent / Model breakdown.
    /// When `nil`, defaults to today (or the most recent active day if today is empty).
    @Published var selectedPeriod: String?

    /// Expanded rows in the daily history section.
    @Published var expandedPeriods: Set<String> = []

    let prefs: CCUsagePreferences

    private let work = DispatchQueue(label: "me.xueshi.xtools.ccusage", qos: .userInitiated)
    private let log = FileLog("CCUsage")
    private var timer: AnyCancellable?
    private var bag = Set<AnyCancellable>()
    private var scanning = false

    // Visibility tracking so we don't spawn `ccusage` every 5s when the window is closed/hidden.
    private var viewVisible = false
    private var windowVisible = true
    private var sessionActive = true
    private var screensAwake = true
    private var pipelineRunning = false

    private weak var hostWindow: NSWindow?
    private var occlusionObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(prefs: CCUsagePreferences = CCUsagePreferences()) {
        self.prefs = prefs

        prefs.$preset
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
            .store(in: &bag)

        prefs.$customSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
            .store(in: &bag)

        observeWorkspace()
    }

    deinit {
        if let token = occlusionObserver { NotificationCenter.default.removeObserver(token) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        timer?.cancel()
    }

    // MARK: - Derived convenience properties

    /// Today's entry (or a zero entry for today's date if none recorded yet).
    var todayEntry: CCDailyEntry {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: Date())
        return report.entry(for: todayKey) ?? CCDailyEntry.zero(period: todayKey)
    }

    /// Yesterday's entry, if any.
    var yesterdayEntry: CCDailyEntry? {
        report.yesterdayEntry()
    }

    /// The entry currently inspected in the Agent & Model breakdown cards.
    var focusedEntry: CCDailyEntry {
        if let sel = selectedPeriod, let found = report.entry(for: sel) {
            return found
        }
        return todayEntry
    }

    // MARK: - Lifecycle

    func start() {
        viewVisible = true
        reevaluatePipeline("view appeared")
    }

    func stop() {
        viewVisible = false
        reevaluatePipeline("view disappeared")
    }

    func attach(window newWindow: NSWindow?) {
        guard newWindow !== hostWindow else { return }
        if let token = occlusionObserver {
            NotificationCenter.default.removeObserver(token)
            occlusionObserver = nil
        }
        hostWindow = newWindow
        guard let window = newWindow else { return }
        // At initial `viewDidMoveToWindow` before `makeKeyAndOrderFront`,
        // `window.isVisible` is still false and `occlusionState` is empty.
        // Treat a not-yet-ordered-front window as visible until the first
        // `didChangeOcclusionStateNotification` arrives.
        windowVisible = window.isVisible ? window.occlusionState.contains(.visible) : true
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
        func on(_ name: Notification.Name, _ change: @escaping (CCUsageStore) -> Void, _ why: String) {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                change(self)
                self.reevaluatePipeline(why)
            })
        }
        on(NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }, "session resigned")
        on(NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }, "session active")
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
            log.info("CCUsage pipeline start (\(reason))")
            refresh()
            rescheduleTimer()
        } else {
            log.info("CCUsage pipeline stop (\(reason))")
            timer?.cancel()
            timer = nil
        }
    }

    private func rescheduleTimer() {
        timer?.cancel()
        timer = nil
        guard pipelineRunning, let seconds = prefs.effectiveSeconds else { return }
        timer = Timer.publish(every: seconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    // MARK: - Refresh

    func refresh() {
        guard !scanning else { return }
        scanning = true
        isRefreshing = true
        work.async { [weak self] in
            let res = CCUsageScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                if res.errorMessage == nil {
                    self.report = res.report
                    self.lastUpdated = res.fetchedAt
                    self.errorMessage = nil
                    self.log.debug("scan finished: \(res.report.daily.count) day(s), totalCost=\(CCFormat.cost(res.report.totals.totalCost))")
                    // Auto-expand today's row on first load
                    if self.expandedPeriods.isEmpty, let latest = res.report.dailyNewestFirst.first {
                        self.expandedPeriods.insert(latest.period)
                    }
                } else {
                    self.log.error("scan failed: \(res.errorMessage ?? "")")
                    self.errorMessage = res.errorMessage
                }
                self.isRefreshing = false
                self.scanning = false
            }
        }
    }
}
