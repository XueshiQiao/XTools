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

    /// Binary installation & update state.
    @Published private(set) var isBinaryInstalled: Bool = CCUsageBinaryManager.isInstalled
    @Published private(set) var isDownloadingBinary: Bool = false
    @Published private(set) var downloadErrorMessage: String?
    @Published private(set) var ccusageVersion: String?
    @Published private(set) var isCheckingUpdate: Bool = false
    @Published private(set) var updateStatusMessage: String?
    /// A background auto-update is in flight (the "Check for Update" button is disabled meanwhile).
    @Published private(set) var isAutoUpdating: Bool = false

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

    /// Every install/update of the managed binary (first-run download, the manual button and the
    /// background auto-update) runs on this serial queue, so a download never holds up a scan on `work`.
    private let updateQueue = DispatchQueue(label: "me.xueshi.xtools.ccusage.update", qos: .utility)
    /// Background auto-update, started by `CCUsageTool.activate()` for the whole app lifetime,
    /// independent of whether the tab is visible.
    private var autoUpdateTimer: AnyCancellable?
    private var autoUpdatesEnabled = false
    /// How often the store asks "is a check due yet?". The actual npm request happens at most
    /// once per `CCUsageBinaryManager.autoUpdateInterval`; a failed check is retried on the next tick.
    private static let autoUpdateTickSeconds: TimeInterval = 60 * 60
    /// Delay before the first check after launch, so it doesn't compete with app start-up.
    private static let autoUpdateLaunchDelay: TimeInterval = 20
    /// Delay after the Mac wakes, so the network has time to come back.
    private static let autoUpdateWakeDelay: TimeInterval = 15

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
        autoUpdateTimer?.cancel()
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
        // The hourly timer doesn't advance while asleep; after a long sleep, check again soon after waking.
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + CCUsageStore.autoUpdateWakeDelay) {
                self?.autoUpdateIfDue()
            }
        })
    }

    private func reevaluatePipeline(_ reason: String) {
        let shouldRun = viewVisible && windowVisible && sessionActive && screensAwake
        guard shouldRun != pipelineRunning else { return }
        pipelineRunning = shouldRun
        if shouldRun {
            log.info("CCUsage pipeline start (\(reason))")
            ensureBinaryThenStart()
        } else {
            log.info("CCUsage pipeline stop (\(reason))")
            timer?.cancel()
            timer = nil
        }
    }

    private func rescheduleTimer() {
        timer?.cancel()
        timer = nil
        guard pipelineRunning, isBinaryInstalled, let seconds = prefs.effectiveSeconds else { return }
        timer = Timer.publish(every: seconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    // MARK: - Binary Management (First-run Download & Check Update)

    private func ensureBinaryThenStart() {
        if CCUsageBinaryManager.isInstalled {
            isBinaryInstalled = true
            if ccusageVersion == nil {
                work.async { [weak self] in
                    let ver = CCUsageBinaryManager.installedVersion()
                    DispatchQueue.main.async {
                        self?.ccusageVersion = ver
                    }
                }
            }
            refresh()
            rescheduleTimer()
        } else {
            isBinaryInstalled = false
            downloadInitialBinary()
        }
    }

    func downloadInitialBinary() {
        guard !isDownloadingBinary, !isCheckingUpdate, !isAutoUpdating else { return }
        isDownloadingBinary = true
        downloadErrorMessage = nil
        log.info("ccusage binary not found; starting initial download")

        updateQueue.async { [weak self] in
            do {
                let outcome = try CCUsageBinaryManager.installOrUpdate()
                let version: String = {
                    switch outcome {
                    case .installed(let v), .upToDate(let v): return v
                    case .updated(_, let to): return to
                    }
                }()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.log.info("ccusage initial install succeeded: v\(version)")
                    self.prefs.lastUpdateCheck = Date()
                    self.isDownloadingBinary = false
                    self.isBinaryInstalled = true
                    self.ccusageVersion = version
                    self.downloadErrorMessage = nil
                    self.refresh()
                    self.rescheduleTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.log.error("ccusage initial install failed: \(error.localizedDescription)")
                    self.isDownloadingBinary = false
                    self.downloadErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func checkAndUpdateCCUsage() {
        guard !isCheckingUpdate, !isDownloadingBinary, !isAutoUpdating else { return }
        isCheckingUpdate = true
        updateStatusMessage = L("ccusage.update.checking")
        log.info("Checking for ccusage update")

        updateQueue.async { [weak self] in
            do {
                let outcome = try CCUsageBinaryManager.installOrUpdate()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.prefs.lastUpdateCheck = Date()
                    self.isCheckingUpdate = false
                    self.isBinaryInstalled = true
                    switch outcome {
                    case .upToDate(let version):
                        self.ccusageVersion = version
                        self.updateStatusMessage = String(format: L("ccusage.update.upToDate"), version)
                    case .updated(let from, let to):
                        self.ccusageVersion = to
                        self.updateStatusMessage = String(format: L("ccusage.update.updated"), from, to)
                        self.refresh()
                    case .installed(let version):
                        self.ccusageVersion = version
                        self.updateStatusMessage = String(format: L("ccusage.update.installed"), version)
                        self.refresh()
                        self.rescheduleTimer()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.log.error("ccusage update check failed: \(error.localizedDescription)")
                    self.isCheckingUpdate = false
                    self.updateStatusMessage = String(format: L("ccusage.update.failed"), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Automatic Update

    /// Starts the background auto-update schedule. Called from `CCUsageTool.activate()` at launch.
    func startAutoUpdates() {
        guard !autoUpdatesEnabled else { return }
        autoUpdatesEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoUpdateLaunchDelay) { [weak self] in
            self?.autoUpdateIfDue()
        }
        autoUpdateTimer = Timer.publish(every: Self.autoUpdateTickSeconds, tolerance: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.autoUpdateIfDue() }
    }

    /// Stops the background auto-update schedule. Called from `CCUsageTool.shutdown()`.
    func stopAutoUpdates() {
        autoUpdatesEnabled = false
        autoUpdateTimer?.cancel()
        autoUpdateTimer = nil
    }

    /// Silently updates an already-installed `ccusage` when the last successful check is older
    /// than `CCUsageBinaryManager.autoUpdateInterval`. A missing binary is left to the first-run
    /// download path (`downloadInitialBinary`), which runs when the tab is opened.
    private func autoUpdateIfDue() {
        guard autoUpdatesEnabled else { return }
        guard !isAutoUpdating, !isCheckingUpdate, !isDownloadingBinary else { return }
        guard CCUsageBinaryManager.isInstalled else { return }
        guard CCUsageBinaryManager.isUpdateCheckDue(lastCheck: prefs.lastUpdateCheck, now: Date()) else { return }

        isAutoUpdating = true
        log.info("Auto-checking for ccusage update")

        updateQueue.async { [weak self] in
            let result = Result { try CCUsageBinaryManager.installOrUpdate() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAutoUpdating = false
                switch result {
                case .success(let outcome):
                    self.prefs.lastUpdateCheck = Date()
                    self.isBinaryInstalled = true
                    switch outcome {
                    case .upToDate(let version):
                        self.log.info("ccusage auto-update: already up to date (v\(version))")
                        self.ccusageVersion = version
                    case .updated(let from, let to):
                        self.log.info("ccusage auto-update: v\(from) → v\(to)")
                        self.ccusageVersion = to
                        self.updateStatusMessage = String(format: L("ccusage.update.updated"), from, to)
                        if self.pipelineRunning { self.refresh() }
                    case .installed(let version):
                        self.log.info("ccusage auto-update: installed v\(version)")
                        self.ccusageVersion = version
                        self.updateStatusMessage = String(format: L("ccusage.update.installed"), version)
                        if self.pipelineRunning { self.refresh() }
                        self.rescheduleTimer()
                    }
                case .failure(let error):
                    // Don't record the check time, so the next hourly tick tries again.
                    self.log.error("ccusage auto-update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard isBinaryInstalled else {
            downloadInitialBinary()
            return
        }
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
