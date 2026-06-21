import SwiftUI

/// The Default Apps tool: manage which app opens which file type / URL scheme —
/// the system "Open with…" defaults — for a curated list of common types and
/// schemes. All changes are user-domain (no sudo) via LaunchServices.
///
/// Self-contained in `Sources/Tools/DefaultApps/`. On-demand scanner + on-demand
/// changes, so no app-lifetime background work (no `activate()`).
final class DefaultAppsTool: XToolModule {

    let id = "default-apps"
    var title: String { L("tool.defaultapps.title") }
    let symbol = "app.badge"
    let color = Color.indigo

    private lazy var store = DefaultAppsStore()

    func makeRootView() -> AnyView { AnyView(DefaultAppsView(store: store)) }
}
