import Foundation

/// The ordered list of tools shown in the sidebar. This is the ONE place that
/// knows which tools exist — adding a tool is a one-line change here.
///
/// Order here = order in the sidebar (above the built-in General / About rows).
enum ToolRegistry {
    static func makeAllTools() -> [any XToolModule] {
        [
            LaunchManagerTool(),
            WakeLocksTool(),
            PowerInsightsTool(),
            DNSToolsTool(),
            DefaultAppsTool(),
            // Add future tools here.
        ]
    }
}
