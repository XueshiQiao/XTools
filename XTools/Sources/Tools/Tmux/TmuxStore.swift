import Foundation
import Combine
import SwiftUI
import AppKit

/// UI model for the Tmux tool. Owns the tree snapshot, search filter, expansion
/// state, and the jump / move-window actions. Fully self-contained so a future
/// standalone hotkey window can host `TmuxView(store:)` without the shell.
final class TmuxStore: ObservableObject {

    @Published private(set) var sessions: [TmuxSessionNode] = []
    @Published private(set) var clients: [String] = []
    @Published private(set) var tmuxPath: String?
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    @Published var actionMessage: String?
    @Published var query: String = ""

    /// Expanded session ids (`$N`) and window ids (`@N`) for the Disclosure tree.
    @Published var expandedSessions: Set<String> = []
    @Published var expandedWindows: Set<String> = []

    /// Currently selected tree row (for keyboard/context actions).
    @Published var selection: TmuxTarget?

    /// True while a window drag is in progress — pauses auto-refresh so the
    /// list doesn't thrash under the cursor mid-drag.
    /// NOT `@Published`: flipping it must not re-render every row mid-drag
    /// (that was a major source of jank).
    private(set) var isDraggingWindow = false

    /// Fired on the main thread after a successful jump. The palette controller
    /// uses this to dismiss itself so focus returns to the terminal.
    var onJumpSucceeded: (() -> Void)?

    private static let log = FileLog("Tmux")

    private let work = DispatchQueue(label: "me.xueshi.xtools.tmux", qos: .userInitiated)
    private var didSeedExpansion = false
    /// Bumped on each begin/end so a late safety-timeout can't clear a newer drag.
    private var dragGeneration: UInt64 = 0
    /// Monotonic refresh id — drop stale async results so an empty race can't
    /// overwrite a good snapshot (was flickering 2 ↔ 0 sessions).
    private var refreshGeneration: UInt64 = 0

    // MARK: - Auto-refresh scheduling
    //
    // Poll only while something is actually showing the data, and never touch
    // the UI when nothing changed:
    //   palette open              → 1s
    //   main tab visible, app front → 2s
    //   main tab visible, app back  → 8s
    //   nothing visible           → stopped
    // An idle tick costs one child process and one tree comparison; equal
    // results publish nothing, so SwiftUI is not invalidated.

    private var mainViewVisible = false
    private var paletteVisible = false
    private var appIsActive = NSApp.isActive
    private var pollTimer: Timer?
    private var currentInterval: TimeInterval?
    /// True while a fetch is on the work queue — timer ticks skip instead of piling up.
    private var inFlight = false
    private var observers: [NSObjectProtocol] = []

    /// Poll counters, folded into one debug line per minute (quiet but auditable).
    private var statPolls = 0
    private var statUnchanged = 0
    private var lastStatsLog = Date()

    /// Watches /tmp/tmux-<uid> so a tmux server starting or dying shows up
    /// right away instead of on the next tick.
    private var socketWatcher: DispatchSourceFileSystemObject?
    private var watcherDebounce: DispatchWorkItem?

    init() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.appActivationChanged()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pollTimer?.invalidate()
        socketWatcher?.cancel()
    }

    func setMainViewVisible(_ visible: Bool) {
        guard mainViewVisible != visible else { return }
        mainViewVisible = visible
        reschedulePolling()
        // Fresh data the moment the tab/window becomes visible again.
        if visible { refresh(userInitiated: true) }
    }

    func setPaletteVisible(_ visible: Bool) {
        guard paletteVisible != visible else { return }
        paletteVisible = visible
        reschedulePolling()
        if visible { refresh(userInitiated: true) }
    }

    private func appActivationChanged() {
        appIsActive = NSApp.isActive
        reschedulePolling()
        // Coming back to the foreground: show fresh data immediately.
        if appIsActive, mainViewVisible || paletteVisible { refresh() }
    }

    private var desiredInterval: TimeInterval? {
        if paletteVisible { return 1 }
        if mainViewVisible { return appIsActive ? 2 : 8 }
        return nil
    }

    private func reschedulePolling() {
        let want = desiredInterval
        guard want != currentInterval else { return }
        currentInterval = want
        pollTimer?.invalidate()
        pollTimer = nil
        guard let want else {
            disarmSocketWatcher()
            Self.log.debug("poll stopped (nothing visible)")
            return
        }
        armSocketWatcher()
        let timer = Timer(timeInterval: want, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Self.log.debug("poll cadence → \(Int(want))s (palette=\(self.paletteVisible) main=\(self.mainViewVisible) appActive=\(self.appIsActive))")
    }

    private func pollTick() {
        // The socket dir may not have existed at arm time (server never started).
        if socketWatcher == nil { armSocketWatcher() }
        maybeLogStats()
        guard !isDraggingWindow, !inFlight else { return }
        refresh()
    }

    private func maybeLogStats() {
        let now = Date()
        guard now.timeIntervalSince(lastStatsLog) >= 60 else { return }
        lastStatsLog = now
        let interval = currentInterval.map { "\(Int($0))s" } ?? "off"
        // FileLog messages are @autoclosure evaluated later on the log queue —
        // capture the counters by value BEFORE resetting them, or it prints 0.
        let polls = statPolls
        let unchanged = statUnchanged
        Self.log.debug("poll stats: \(polls) poll(s), \(unchanged) unchanged, interval=\(interval)")
        statPolls = 0
        statUnchanged = 0
    }

    private func armSocketWatcher() {
        guard socketWatcher == nil, currentInterval != nil else { return }
        let path = "/tmp/tmux-\(getuid())"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return } // dir absent (no server yet); retried each tick
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let flags = self.socketWatcher?.data,
               !flags.intersection([.delete, .rename]).isEmpty {
                self.disarmSocketWatcher() // dir replaced — re-armed on next tick
            }
            // Debounce bursts; a socket appeared/vanished → look right away.
            self.watcherDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.currentInterval != nil, !self.isDraggingWindow else { return }
                self.refresh()
            }
            self.watcherDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        socketWatcher = source
        Self.log.debug("socket dir watcher armed (\(path))")
    }

    private func disarmSocketWatcher() {
        socketWatcher?.cancel()
        socketWatcher = nil
    }

    // MARK: - Derived

    /// Sessions filtered by the search query (matches session / window / pane labels).
    var filteredSessions: [TmuxSessionNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.compactMap { session in
            if session.name.lowercased().contains(q) { return session }
            let windows = session.windows.compactMap { window -> TmuxWindowNode? in
                if window.name.lowercased().contains(q)
                    || String(window.index).contains(q) {
                    return window
                }
                let panes = window.panes.filter {
                    $0.displayName.lowercased().contains(q)
                        || $0.currentCommand.lowercased().contains(q)
                        || $0.currentPath.lowercased().contains(q)
                        || $0.id.lowercased().contains(q)
                }
                if panes.isEmpty { return nil }
                return TmuxWindowNode(
                    id: window.id, index: window.index, name: window.name,
                    sessionID: window.sessionID, sessionName: window.sessionName,
                    active: window.active, panes: panes
                )
            }
            if windows.isEmpty { return nil }
            return TmuxSessionNode(
                id: session.id, name: session.name, attached: session.attached,
                windows: windows
            )
        }
    }

    var sessionCount: Int { sessions.count }
    var windowCount: Int { sessions.reduce(0) { $0 + $1.windowCount } }
    var paneCount: Int { sessions.reduce(0) { $0 + $1.paneCount } }

    /// Other session names a window can be moved into (everything except its own).
    func destinationSessions(for window: TmuxWindowNode) -> [TmuxSessionNode] {
        sessions.filter { $0.id != window.sessionID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func window(id: String) -> TmuxWindowNode? {
        for s in sessions {
            if let w = s.windows.first(where: { $0.id == id }) { return w }
        }
        return nil
    }

    // MARK: - Refresh

    /// `userInitiated` drives the spinner: background ticks never touch
    /// `isScanning` (a @Published write every tick would invalidate the whole
    /// tree view even when nothing changed).
    func refresh(userInitiated: Bool = false) {
        // Don't rebuild the tree while the user is mid-drag — drop targets vanish.
        if isDraggingWindow { return }
        if userInitiated { isScanning = true }
        refreshGeneration &+= 1
        let gen = refreshGeneration
        inFlight = true
        work.async { [weak self] in
            do {
                let snap = try TmuxCLI.fetchSnapshot()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    guard self.refreshGeneration == gen else { return }
                    self.statPolls += 1
                    // Never let a transient empty read wipe a non-empty tree unless
                    // we also got a hard error (handled below).
                    if snap.sessions.isEmpty, !self.sessions.isEmpty {
                        Self.log.warn("ignoring empty snapshot (kept \(self.sessions.count) sessions)")
                        if self.isScanning { self.isScanning = false }
                        return
                    }
                    // Unchanged → publish nothing. This is what makes an idle
                    // tick cost one process and one comparison, not a UI pass.
                    if snap.sessions == self.sessions,
                       snap.clients == self.clients,
                       snap.tmuxPath == self.tmuxPath,
                       self.lastError == nil {
                        self.statUnchanged += 1
                        if self.isScanning { self.isScanning = false }
                        return
                    }
                    self.sessions = snap.sessions
                    self.clients = snap.clients
                    self.tmuxPath = snap.tmuxPath
                    self.lastError = nil
                    if self.isScanning { self.isScanning = false }
                    self.seedExpansionIfNeeded()
                    self.pruneExpansion()
                    Self.log.debug("snapshot: \(snap.sessions.count) sessions, \(snap.clients.count) client(s) via \(snap.tmuxPath)")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    guard self.refreshGeneration == gen else { return }
                    if self.isScanning { self.isScanning = false }
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    if self.lastError != message {
                        self.lastError = message
                        Self.log.debug("refresh failed: \(message)")
                    }
                    // Only clear the tree on hard failure if we had nothing useful.
                    if self.sessions.isEmpty, self.actionMessage != message {
                        self.actionMessage = message
                    }
                }
            }
        }
    }

    /// First successful load: expand every session so windows are visible; leave
    /// windows collapsed (panes stay hidden until the user opens a window).
    private func seedExpansionIfNeeded() {
        guard !didSeedExpansion else { return }
        didSeedExpansion = true
        expandedSessions = Set(sessions.map(\.id))
        // expandedWindows intentionally left empty — panes stay collapsed by default.
    }

    private func pruneExpansion() {
        let sessionIDs = Set(sessions.map(\.id))
        let windowIDs = Set(sessions.flatMap { $0.windows.map(\.id) })
        expandedSessions = expandedSessions.intersection(sessionIDs)
        expandedWindows = expandedWindows.intersection(windowIDs)
    }

    // MARK: - Expand helpers

    func isSessionExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedSessions.contains(id) },
            set: { open in
                if open { self.expandedSessions.insert(id) }
                else { self.expandedSessions.remove(id) }
            }
        )
    }

    func isWindowExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedWindows.contains(id) },
            set: { open in
                if open { self.expandedWindows.insert(id) }
                else { self.expandedWindows.remove(id) }
            }
        )
    }

    func toggleSessionExpanded(_ id: String) {
        // Disable implicit insertion animations — expanding a session with many
        // windows must not run a spring layout on every new row (felt like lag).
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if expandedSessions.contains(id) { expandedSessions.remove(id) }
            else { expandedSessions.insert(id) }
        }
    }

    func toggleWindowExpanded(_ id: String) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if expandedWindows.contains(id) { expandedWindows.remove(id) }
            else { expandedWindows.insert(id) }
        }
    }

    func expandAll() {
        expandedSessions = Set(sessions.map(\.id))
        expandedWindows = Set(sessions.flatMap { $0.windows.map(\.id) })
    }

    func collapseAll() {
        expandedSessions.removeAll()
        expandedWindows.removeAll()
    }

    // MARK: - Drag lifecycle

    func beginWindowDrag() {
        isDraggingWindow = true
        dragGeneration &+= 1
        let gen = dragGeneration
        // Cancelled drags don't call endWindowDrag — release the refresh pause
        // after a generous timeout so a stuck flag can't freeze the tree forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.dragGeneration == gen else { return }
            self.isDraggingWindow = false
        }
    }

    func endWindowDrag() {
        dragGeneration &+= 1
        isDraggingWindow = false
    }

    // MARK: - Actions

    func jump(_ target: TmuxTarget) {
        work.async { [weak self] in
            do {
                try TmuxCLI.jump(to: target, preferredClient: self?.clients.first)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.actionMessage = L("tmux.msg.jumped")
                    // Notify before refresh so the palette can dismiss immediately.
                    self.onJumpSucceeded?()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.actionMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    func moveWindow(_ window: TmuxWindowNode, to session: TmuxSessionNode) {
        moveWindow(id: window.id, name: window.name, to: .endOfSession(name: session.name),
                   expandSessionID: session.id)
    }

    /// Move by stable window id (used by drag-and-drop, which only carries the id).
    func moveWindow(id windowID: String, name: String? = nil,
                    to placement: TmuxCLI.WindowPlacement,
                    expandSessionID: String? = nil) {
        // No-op: dropping a window onto itself.
        if case .beforeWindow(let dest) = placement, dest == windowID { return }
        if case .afterWindow(let dest) = placement, dest == windowID { return }

        let displayName = name ?? window(id: windowID)?.name ?? windowID
        let expandID = expandSessionID ?? sessionID(for: placement)

        work.async { [weak self] in
            do {
                try TmuxCLI.moveWindow(windowID: windowID, to: placement)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.actionMessage = String(
                        format: L("tmux.msg.moved"),
                        displayName,
                        self.placementDescription(placement)
                    )
                    if let expandID {
                        self.expandedSessions.insert(expandID)
                    }
                    self.endWindowDrag()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.actionMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self?.endWindowDrag()
                    self?.refresh()
                }
            }
        }
    }

    private func sessionID(for placement: TmuxCLI.WindowPlacement) -> String? {
        switch placement {
        case .endOfSession(let name):
            return sessions.first(where: { $0.name == name })?.id
        case .beforeWindow(let id), .afterWindow(let id):
            return window(id: id)?.sessionID
        }
    }

    private func placementDescription(_ placement: TmuxCLI.WindowPlacement) -> String {
        switch placement {
        case .endOfSession(let name):
            return name
        case .beforeWindow(let id):
            if let w = window(id: id) {
                return "\(w.sessionName):\(w.index) (\(w.name))"
            }
            return id
        case .afterWindow(let id):
            if let w = window(id: id) {
                return "\(w.sessionName):\(w.index)+ (\(w.name))"
            }
            return id
        }
    }
}
