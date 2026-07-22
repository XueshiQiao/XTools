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

    private let work = DispatchQueue(label: "me.xueshi.xtools.tmux", qos: .userInitiated)
    private var didSeedExpansion = false

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

    /// First successful load: expand attached sessions and their active windows.
    private func seedExpansionIfNeeded() {
        guard !didSeedExpansion else { return }
        didSeedExpansion = true
        for s in sessions where s.attached {
            expandedSessions.insert(s.id)
            for w in s.windows where w.active {
                expandedWindows.insert(w.id)
            }
        }
        // If nothing attached, expand the first session so the page isn't a wall of closed rows.
        if expandedSessions.isEmpty, let first = sessions.first {
            expandedSessions.insert(first.id)
        }
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

    func expandAll() {
        expandedSessions = Set(sessions.map(\.id))
        expandedWindows = Set(sessions.flatMap { $0.windows.map(\.id) })
    }

    func collapseAll() {
        expandedSessions.removeAll()
        expandedWindows.removeAll()
    }

    // MARK: - Actions

    func jump(_ target: TmuxTarget) {
        work.async { [weak self] in
            do {
                try TmuxCLI.jump(to: target, preferredClient: self?.clients.first)
                DispatchQueue.main.async {
                    self?.actionMessage = L("tmux.msg.jumped")
                    self?.refresh()
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
        work.async { [weak self] in
            do {
                try TmuxCLI.moveWindow(windowID: window.id, toSessionName: session.name)
                DispatchQueue.main.async {
                    self?.actionMessage = String(
                        format: L("tmux.msg.moved"),
                        window.name,
                        session.name
                    )
                    // Keep the destination open so the user sees the moved window.
                    self?.expandedSessions.insert(session.id)
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.actionMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }
}
