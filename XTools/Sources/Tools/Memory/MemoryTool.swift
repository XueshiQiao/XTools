import SwiftUI

/// The Memory tool: surfaces the macOS memory-pressure signal (the green/yellow/
/// red the kernel uses) plus the core memory metrics from Activity Monitor's
/// Memory tab — Free / Active / Inactive / Wired / Compressed / Purgeable and
/// swap — each with a plain-language explanation. All read-only, no sudo.
///
/// Self-contained in `Sources/Tools/Memory/`. On-demand + ~5s auto-refresh
/// scanner only, so no app-lifetime background work (no `activate()`).
final class MemoryTool: XToolModule {

    let id = "memory"
    var title: String { L("tool.memory.title") }
    let symbol = "memorychip"
    let color = Color.pink

    private lazy var store = MemoryStore()

    func makeRootView() -> AnyView { AnyView(MemoryView(store: store)) }
}
