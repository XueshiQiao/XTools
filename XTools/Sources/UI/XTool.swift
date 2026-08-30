import SwiftUI

/// A single XTools tool: one sidebar tab, one isolated `Sources/Tools/<Name>/`
/// folder. This is the contract every tool implements so the shell can list it,
/// route to it, and start its background work — the shell never needs to know a
/// tool's internals.
///
/// Add a new tool by: creating `Sources/Tools/<Name>/`, implementing this
/// protocol on a `<Name>Tool` class, and adding one line to `ToolRegistry`.
///
/// Main-thread only by convention (like the rest of the SwiftUI/AppKit layer);
/// not actor-isolated so it composes with AppKit controllers on macOS 13.
/// Which sidebar block a tool sits in. Cases are listed in the order the blocks
/// appear, and each block is separated the way macOS System Settings separates
/// its groups — by a gap, with no header.
enum ToolGroup: CaseIterable {
    /// Tools you reach for while working in *another* app — they act on whatever
    /// you have selected, and their real UI is a popup, not this window.
    case selection
    /// "What is going on right this second" — something is making noise, something
    /// is stopping the Mac from sleeping. Short-lived answers you check and leave.
    case liveActivity
    /// Tools that inspect or manage this Mac. The default group.
    case system
    /// Long-lived things that outlive the window that started them: launchd items
    /// and tmux sessions.
    case background
    /// Tools that drive a specific piece of hardware plugged into it. These are
    /// only useful to someone who owns that device, so they read better set apart
    /// from the ones that apply to every Mac.
    case devices
}

protocol XToolModule: AnyObject {
    /// Stable, language-independent id — used for routing, accessibility ids, and
    /// analytics. Never localize this.
    var id: String { get }

    /// Which sidebar block this tool belongs to. Default: `.system`.
    var group: ToolGroup { get }

    /// Localized sidebar label and navigation title.
    var title: String { get }

    /// SF Symbol shown in the sidebar tile.
    var symbol: String { get }

    /// Accent color of the sidebar tile.
    var color: Color { get }

    /// Called once at app launch — start any app-lifetime background work (e.g.
    /// the Launch Manager's Guardian reaper) so it runs even with the window
    /// closed. Default: no-op.
    func activate()

    /// Called at app termination — stop background work cleanly. Default: no-op.
    func shutdown()

    /// The tool's root SwiftUI page. Built lazily when first shown; the tool
    /// owns its (stable) store, so rebuilding the view is cheap.
    func makeRootView() -> AnyView

    /// Extra window width this page needs beyond the shared default. Most tools are
    /// a single narrow column and return 0; a tool with an extra side panel (the
    /// process list's detail column) returns its width, and the shell grows the
    /// window by that much while this tool is selected, restoring it on the way out.
    var preferredExtraWidth: CGFloat { get }
}

extension XToolModule {
    func activate() {}
    func shutdown() {}
    var preferredExtraWidth: CGFloat { 0 }
    var group: ToolGroup { .system }
}

/// What the sidebar can select: the dashboard, a tool (by id), or one of the
/// built-in pages.
enum SidebarItem: Hashable {
    case dashboard
    case tool(String)
    case models
    case general
    case about

    /// Stable id stem for accessibility identifiers.
    var axID: String {
        switch self {
        case .dashboard:    return "dashboard"
        case .tool(let id): return "tool_\(id)"
        case .models:       return "models"
        case .general:      return "general"
        case .about:        return "about"
        }
    }
}
