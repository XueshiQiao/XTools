import SwiftUI

/// The Device Tree tool: everything attached to this Mac, and how it is attached.
///
/// Nothing here is specific to one machine. Each section is filled in by asking
/// the framework that owns that domain, and the physical nesting comes from the
/// IOKit registry, so a Mac with a dock, a Mac with a single keyboard, and a Mac
/// with nothing plugged in all render through the same code.
final class DeviceTreeTool: XToolModule {

    let id = "device-tree"
    var title: String { L("tool.devicetree.title") }
    let symbol = "point.3.connected.trianglepath.dotted"
    let color = Color.teal
    let group = ToolGroup.devices

    let store = DeviceTreeStore()

    func activate() { store.start() }
    func shutdown() { store.stop() }

    func makeRootView() -> AnyView { AnyView(DeviceTreeView(store: store)) }
}
