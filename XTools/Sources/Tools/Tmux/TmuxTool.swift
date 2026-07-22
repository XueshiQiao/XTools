import SwiftUI

/// Tmux Manager tool: tree of sessions / windows / panes, jump, and
/// cross-session window move — plus a global hotkey that opens a shell-free
/// palette window for the same tree.
///
/// Everything lives under `Sources/Tools/Tmux/`.
final class TmuxTool: XToolModule {

    let id = "tmux"
    var title: String { L("tool.tmux.title") }
    let symbol = "terminal"
    let color = Color.teal

    /// Single store shared by the sidebar page and the hotkey palette.
    private lazy var store = TmuxStore()
    /// Owns the Carbon hotkey + floating panel. Started in `activate()`.
    private lazy var palette = TmuxPaletteController(store: store)

    func activate() {
        palette.startIfEnabled()
    }

    func shutdown() {
        palette.stop()
    }

    func makeRootView() -> AnyView {
        AnyView(TmuxView(store: store, palette: palette, presentation: .embedded))
    }
}
