import SwiftUI

/// The Power & Battery Insights tool: surfaces battery health, the active
/// `pmset` power/sleep settings, and recent wake/sleep events — all read-only,
/// no sudo. Pairs with Wake Locks as the app's "Power" theme.
///
/// Self-contained in `Sources/Tools/PowerInsights/`. On-demand scanner only, so
/// no app-lifetime background work (no `activate()`).
final class PowerInsightsTool: XToolModule {

    let id = "power-insights"
    var title: String { L("tool.power.title") }
    let symbol = "bolt.batteryblock.fill"
    let color = Color.green

    private lazy var store = PowerInsightsStore()

    func makeRootView() -> AnyView { AnyView(PowerInsightsView(store: store)) }
}
