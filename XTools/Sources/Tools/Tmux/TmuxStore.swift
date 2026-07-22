import Foundation
import Combine
import SwiftUI

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

    private let work = DispatchQueue(label: "me.xueshi.xtools.tmux", qos: .userInitiated)
    private var didSeedExpansion = false
    /// Bumped on each begin/end so a late safety-timeout can't clear a newer drag.
    private var dragGeneration: UInt64 = 0

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

    func refresh() {
        // Don't rebuild the tree while the user is mid-drag — drop targets vanish.
        if isDraggingWindow { return }
        isScanning = true
        work.async { [weak self] in
            do {
                let snap = try TmuxCLI.fetchSnapshot()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sessions = snap.sessions
                    self.clients = snap.clients
                    self.tmuxPath = snap.tmuxPath
                    self.lastError = nil
                    self.isScanning = false
                    self.seedExpansionIfNeeded()
                    self.pruneExpansion()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isScanning = false
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.lastError = message
                    // Server gone / list failed: clear the tree so we don't show
                    // stale sessions that no longer exist (actions would target ghosts).
                    self.sessions = []
                    self.clients = []
                    self.actionMessage = message
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
