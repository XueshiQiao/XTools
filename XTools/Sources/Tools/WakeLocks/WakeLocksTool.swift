import SwiftUI

/// The Wake Locks tool: shows which processes are holding power assertions that
/// keep the display or the whole Mac awake (the programmatic `pmset -g assertions`),
/// and lets you end the offending process.
///
/// Self-contained in `Sources/Tools/WakeLocks/`. Read-only scanner + on-demand
/// actions, so no app-lifetime background work (no `activate()`).
final class WakeLocksTool: XToolModule {

    let id = "wake-locks"
    var title: String { L("tool.wake.title") }
    let symbol = "cup.and.saucer.fill"
    let color = Color.orange

    private lazy var store = WakeLocksStore()

    func makeRootView() -> AnyView { AnyView(WakeLocksView(store: store)) }
}
