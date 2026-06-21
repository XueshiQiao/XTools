import SwiftUI
import Combine

/// The root model for the XTools window. Owns the tool registry, the current
/// sidebar selection, and the shared `UpdateController`. Created once at app
/// launch (in `AppDelegate`) so tools' background work starts immediately and
/// survives the window being closed.
///
/// Main-thread only (SwiftUI bindings + `.main` notification observers).
final class AppState: ObservableObject {

    let updateController: UpdateController

    /// All tools, in sidebar order. Each is long-lived (owns its store/services).
    let tools: [any XToolModule]

    @Published var selection: SidebarItem {
        didSet {
            guard oldValue != selection else { return }
            if case .tool(let id) = selection { Analytics.trackToolOpened(id) }
        }
    }

    /// Bumped on an in-app language change so the SwiftUI tree re-reads every
    /// `NSLocalizedString`. The selection is store-backed, so it survives the rebuild.
    @Published private(set) var languageRevision = 0

    private var languageObserver: NSObjectProtocol?

    init(updateController: UpdateController) {
        self.updateController = updateController
        let tools = ToolRegistry.makeAllTools()
        self.tools = tools
        // Default to the first tool; `XTOOLS_TAB=<tool id>` overrides (dev/screenshot
        // affordance, inert in normal use).
        let envTab = ProcessInfo.processInfo.environment["XTOOLS_TAB"]
        if let envTab, tools.contains(where: { $0.id == envTab }) {
            self.selection = .tool(envTab)
        } else {
            self.selection = tools.first.map { SidebarItem.tool($0.id) } ?? .general
        }

        // Start each tool's app-lifetime background work.
        tools.forEach { $0.activate() }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .xtoolsLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.languageRevision &+= 1
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    func tool(for id: String) -> (any XToolModule)? {
        tools.first { $0.id == id }
    }

    /// Stop all tools' background work (called from `applicationWillTerminate`).
    func shutdown() {
        tools.forEach { $0.shutdown() }
    }
}
