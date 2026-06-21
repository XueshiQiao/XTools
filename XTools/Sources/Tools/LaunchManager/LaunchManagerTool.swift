import SwiftUI

/// The Launch Manager tool: find and clean up "ghost" background processes left
/// behind after an app is quit, manage LaunchAgents/Daemons, and set up Guardian
/// rules that auto-reap an app's leftover helpers whenever it isn't running.
///
/// Self-contained in `Sources/Tools/LaunchManager/`. The tool owns the
/// app-lifetime `GuardianReaper` (started in `activate()`) and the UI store.
final class LaunchManagerTool: XToolModule {

    let id = "launch-manager"
    var title: String { L("tool.launch.title") }
    let symbol = "bolt.horizontal.circle.fill"
    let color = Color.blue

    private let reaper = GuardianReaper()
    private lazy var store = LaunchManagerStore(reaper: reaper)

    func activate() { reaper.start() }
    func shutdown() { reaper.stop() }

    func makeRootView() -> AnyView { AnyView(LaunchManagerView(store: store)) }
}
