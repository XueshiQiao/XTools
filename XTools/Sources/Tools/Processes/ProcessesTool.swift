import SwiftUI

/// Process Insight: an Activity-Monitor-style process list whose point is not the
/// list but the question the list can't answer — *what is this thing?* Select a
/// process and a model explains it, grounded in facts XTools computes locally
/// (code signature, owning LaunchAgent/Daemon) rather than in the process's own
/// self-reported name.
///
/// Self-contained in `Sources/Tools/Processes/`. Read-only scanner + on-demand
/// actions, so there is no app-lifetime background work (no `activate()`): nothing
/// samples unless the page is on screen.
///
/// The tool `id` is `"processes"` and is NOT the display title. The title is a
/// human-facing, localized string ("Process Insight" / 「进程洞察」); the id is a
/// machine-facing constant used for routing, analytics and `run.sh --tab processes`.
/// Renaming the title must never touch the id.
final class ProcessesTool: XToolModule {

    let id = "processes"
    var title: String { L("tool.processes.title") }
    let symbol = "cpu"
    let color = Color.purple

    private let llm: LLMService
    private lazy var store = ProcessesStore()

    init(llm: LLMService) {
        self.llm = llm
    }

    func makeRootView() -> AnyView { AnyView(ProcessesView(store: store)) }
}
