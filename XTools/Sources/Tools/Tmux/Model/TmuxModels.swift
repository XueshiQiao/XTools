import Foundation

/// One tmux session with its windows (and each window's panes).
/// Stable identity is `session_id` (`$N`), not the human name.
struct TmuxSessionNode: Identifiable, Hashable {
    /// `#{session_id}` e.g. `$10`
    let id: String
    let name: String
    let attached: Bool
    let windows: [TmuxWindowNode]

    var windowCount: Int { windows.count }
    var paneCount: Int { windows.reduce(0) { $0 + $1.panes.count } }
}

/// One tmux window. Stable identity is `window_id` (`@N`).
struct TmuxWindowNode: Identifiable, Hashable {
    /// `#{window_id}` e.g. `@20`
    let id: String
    let index: Int
    let name: String
    let sessionID: String
    let sessionName: String
    let active: Bool
    let panes: [TmuxPaneNode]
}

/// One tmux pane. Stable identity is `pane_id` (`%N`).
/// Panes have no first-class name — `displayName` is synthesized for the tree.
struct TmuxPaneNode: Identifiable, Hashable {
    /// `#{pane_id}` e.g. `%89`
    let id: String
    let index: Int
    let title: String
    let currentCommand: String
    let currentPath: String
    let active: Bool
    let windowID: String
    let sessionID: String
    let sessionName: String
    let windowName: String

    /// Best-effort label for the tree: prefer a meaningful title, else command, else path basename.
    var displayName: String {
        let hostish = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Default pane titles are often the machine hostname — treat those as unhelpful.
        if !hostish.isEmpty,
           !hostish.hasSuffix(".local"),
           hostish != ProcessInfo.processInfo.hostName {
            return hostish
        }
        let cmd = currentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty { return cmd }
        let path = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return id
    }

    var subtitle: String {
        var parts: [String] = []
        if !currentCommand.isEmpty { parts.append(currentCommand) }
        if !currentPath.isEmpty { parts.append(currentPath) }
        return parts.joined(separator: " · ")
    }
}

/// Selection / jump target inside the tree.
///
/// `tmuxFlag` is always a form `switch-client -t` accepts for changing
/// session/window/pane. Pane targets use `%N` (contains `%`); window targets
/// use `session:@id` (contains `:`) so they work even on builds that reject a
/// bare `@id` session lookup.
enum TmuxTarget: Hashable, Identifiable {
    case session(name: String)
    case window(sessionName: String, windowID: String)
    case pane(id: String)

    var id: String {
        switch self {
        case .session(let name):              return "s:\(name)"
        case .window(_, let windowID):        return "w:\(windowID)"
        case .pane(let paneID):               return "p:\(paneID)"
        }
    }

    /// Argument for `switch-client -t`.
    var tmuxFlag: String {
        switch self {
        case .session(let name):
            return name
        case .window(let sessionName, let windowID):
            return "\(sessionName):\(windowID)"
        case .pane(let paneID):
            return paneID
        }
    }
}

/// Snapshot of the whole server tree + attached clients.
struct TmuxSnapshot: Hashable {
    let sessions: [TmuxSessionNode]
    /// Client tty names, most-recently-active first.
    let clients: [String]
    let tmuxPath: String
}
