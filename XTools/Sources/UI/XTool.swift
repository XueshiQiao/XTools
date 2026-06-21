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
protocol XToolModule: AnyObject {
    /// Stable, language-independent id — used for routing, accessibility ids, and
    /// analytics. Never localize this.
    var id: String { get }

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
}

extension XToolModule {
    func activate() {}
    func shutdown() {}
}

/// What the sidebar can select: a tool (by id) or one of the built-in pages.
enum SidebarItem: Hashable {
    case tool(String)
    case general
    case about

    /// Stable id stem for accessibility identifiers.
    var axID: String {
        switch self {
        case .tool(let id): return "tool_\(id)"
        case .general:      return "general"
        case .about:        return "about"
        }
    }
}
