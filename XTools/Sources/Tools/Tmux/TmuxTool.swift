import SwiftUI

/// Tmux Manager tool: tree of sessions / windows / panes, jump, and
/// cross-session window move.
///
/// Everything lives under `Sources/Tools/Tmux/` so a future hotkey can present
/// only `makeRootView()` (or `TmuxView(store:)`) without the XTools shell.
final class TmuxTool: XToolModule {

    let id = "tmux"
    var title: String { L("tool.tmux.title") }
    let symbol = "terminal"
    let color = Color.teal

    /// Owned for the app lifetime so a future standalone window can reuse the
    /// same store instance (or create its own — the view only needs any store).
    private lazy var store = TmuxStore()

    func makeRootView() -> AnyView { AnyView(TmuxView(store: store)) }
}
