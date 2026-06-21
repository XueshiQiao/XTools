import SwiftUI

/// The Ports & Connections tool: lists listening ports ("who's on :3000") and
/// active network connections by parsing `lsof`, and lets you kill the owning
/// process. A native Swift port of the author's netstat-cat.
///
/// Self-contained in `Sources/Tools/Ports/`. Read-only scanner + on-demand
/// actions, so no app-lifetime background work (no `activate()`).
final class PortsTool: XToolModule {

    let id = "ports"
    var title: String { L("tool.ports.title") }
    let symbol = "network"
    let color = Color.blue

    private lazy var store = PortsStore()

    func makeRootView() -> AnyView { AnyView(PortsView(store: store)) }
}
