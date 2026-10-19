import SwiftUI

/// The CCUsage tool module: tracks daily and cumulative AI coding agent token usage
/// and cost (`ccusage daily --json --by-agent`).
final class CCUsageTool: XToolModule {
    let id = "ccusage"
    let group: ToolGroup = .liveActivity
    var title: String { L("tool.ccusage.title") }
    let symbol = "chart.bar.xaxis"
    let color: Color = .orange

    let store = CCUsageStore()

    func makeRootView() -> AnyView {
        AnyView(CCUsageView(store: store))
    }
}
