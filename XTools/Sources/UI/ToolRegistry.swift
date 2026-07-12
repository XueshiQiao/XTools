import Foundation

/// The ordered list of tools shown in the sidebar. This is the ONE place that
/// knows which tools exist — adding a tool is a one-line change here.
///
/// Order here = order in the sidebar (above the built-in General / About rows).
enum ToolRegistry {
    /// Builds every tool, injecting app-level shared services (e.g. `LLMService`)
    /// into the tools that consume them — preferred over a global singleton so
    /// AppState stays the single owner of both the tools and the services.
    static func makeAllTools(llm: LLMService) -> [any XToolModule] {
        [
            PopBarTool(llm: llm),
            ProcessesTool(llm: llm),
            LaunchManagerTool(),
            WakeLocksTool(),
            NowPlayingTool(),
            PowerInsightsTool(),
            DNSToolsTool(),
            DefaultAppsTool(),
            PortsTool(),
            MemoryTool(),
            // Add future tools here.
        ]
    }
}
