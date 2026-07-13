import SwiftUI

/// The Naga tool: remaps the Razer Naga V2 Pro side buttons (wired USB-C) to
/// user-defined keyboard shortcuts. Self-contained in `Sources/Tools/Naga/`.
///
/// The numbered side buttons are emitted by the mouse's on-board profile as
/// *keyboard keystrokes* (often modifier+key combos), not distinct mouse buttons —
/// so remapping means intercepting those keystrokes (only the ones from the Razer
/// device) and synthesizing a chosen shortcut instead. The listener runs
/// app-lifetime (started in `activate()`) so it works with the window closed.
final class NagaTool: XToolModule {

    let id = "naga"
    var title: String { L("tool.naga.title") }
    let symbol = "square.grid.3x3.fill"
    let color = Color.green

    // NOTE: seize (exclusive HID grab) is denied by macOS for keyboard-type
    // devices (kIOReturnNotPrivileged), so interception moves to a CGEventTap.
    // Listen mode keeps the live input monitor working until that lands.
    let store = NagaStore(backend: SeizeBackend(mode: .listen))

    func activate() { store.start() }
    func shutdown() { store.stop() }

    func makeRootView() -> AnyView { AnyView(NagaView(store: store)) }
}
