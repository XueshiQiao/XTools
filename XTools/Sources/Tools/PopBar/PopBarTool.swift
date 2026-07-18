import SwiftUI

/// PopBar: select text anywhere → a small capsule of customizable, AI-flavored
/// actions pops up at the cursor. Self-contained in `Sources/Tools/PopBar/`.
///
/// The tool owns the app-lifetime `PopBarController` (started in `activate()` so
/// the popup works even with the window closed) and the settings store.
///
/// Layers (each independently replaceable):
///  - Trigger  — `GlobalInputMonitor` + gesture recognizers
///  - Selection — `SelectionResolver` over pluggable `SelectionStrategy`s
///  - Window   — `PopBarPanel` (non-activating floating capsule)
///  - Action   — `ActionRegistry` (Copy real; Translate/Polish/Explain faked)
final class PopBarTool: XToolModule {

    let id = "popbar"
    var title: String { L("tool.popbar.title") }
    let symbol = "text.bubble.fill"
    let color = Color.indigo

    /// The app-level shared LLM service, injected by `ToolRegistry`. PopBar no
    /// longer owns the model config — it lives on the AI Models page.
    private let llm: LLMService
    private let actionStore = ActionStore()
    private lazy var controller = PopBarController(llm: llm, actionStore: actionStore)
    private lazy var store = PopBarStore(controller: controller)

    init(llm: LLMService) {
        self.llm = llm
    }

    func activate() {
        controller.startIfEnabled()
        controller.startOCRIfEnabled()   // screenshot-OCR hotkey is independent of the selection monitor
        // Dev/screenshot affordance: pop a sample capsule shortly after launch.
        if ProcessInfo.processInfo.environment["XTOOLS_POPBAR_PREVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller.showPreview()
            }
        }
    }

    func shutdown() {
        controller.stop()
        controller.stopScreenOCR()   // OCR isn't torn down by stop() (independent lifecycle)
    }

    func makeRootView() -> AnyView { AnyView(PopBarView(store: store, llm: llm, actions: actionStore)) }
}
