import SwiftUI

/// The ROG Keyboard tool: keeps an ASUS ROG Falcata's on-board profile in step
/// with which computer it is plugged into.
///
/// The keyboard talks to two machines at once — a USB-C cable to this Mac and a
/// 2.4 GHz receiver in a PC — and a switch on its body picks which one is live.
/// Its profiles are not tied to that switch, so the Mac key map follows you to
/// Windows and vice versa. This tool puts the right profile back.
///
/// The monitor runs app-lifetime (started in `activate()`) so the keyboard is
/// corrected even with the XTools window closed.
final class ROGKeyboardTool: XToolModule {

    let id = "rog-keyboard"
    var title: String { L("tool.rogkeyboard.title") }
    let symbol = "keyboard"
    let color = Color.indigo
    let group = ToolGroup.devices

    let store = ROGKeyboardStore()

    func activate() { store.start() }
    func shutdown() { store.stop() }

    func makeRootView() -> AnyView { AnyView(ROGKeyboardView(store: store)) }
}
