import AppKit

/// One popup window plus ALL the per-window state that drives it: the captured
/// selection text and the streaming/cancellation generations for the action
/// running inside THIS window. (Issue #13.) The window's on-screen placement is
/// owned by its `PopBarPanel` (the single source of truth for position).
///
/// Before #13 this state lived on `PopBarController` as controller-global fields,
/// so there could only ever be one popup and a new selection cancelled whatever
/// was streaming. By moving it onto a per-window session, multiple windows each
/// own their own panel + in-flight stream: pinning a window "graduates" its
/// session into the pinned set, and a new selection recycles a *fresh* transient
/// session without touching any pinned session's stream.
///
/// Main-thread only by convention (NSEvent monitor callbacks, SwiftUI callbacks,
/// and `activate()` all arrive on main; the resolver `Task` hops back to main
/// before touching a session). The only off-main work is the action `Task`, which
/// hops to `MainActor` before mutating the panel.
final class PopBarSession {

    private static let log = FileLog("PopBar.Session")

    let panel = PopBarPanel()

    private let llmStore: PopBarLLMStore

    /// The text the visible capsule is acting on (this window's selection).
    private(set) var text = ""

    /// Bumped on every show/recycle of THIS window so a slow AI action can't apply
    /// its result onto a capsule that has since been replaced or dismissed.
    private var panelGeneration = 0
    /// Bumped on every action run within THIS window. A second action tapped on the
    /// SAME visible capsule (so `panelGeneration` is unchanged) must not have the
    /// prior stream's already-enqueued MainActor delta tasks overwrite the new
    /// result — they check this token too and bail.
    private var actionGeneration = 0
    /// The in-flight AI action (streaming) for THIS window. Cancelled when a new
    /// action is tapped in this window or this window is dismissed — never by a new
    /// selection elsewhere, so a pinned window keeps streaming undisturbed.
    private var actionTask: Task<Void, Never>?

    init(llmStore: PopBarLLMStore) {
        self.llmStore = llmStore
    }

    var isVisible: Bool { panel.isVisible }
    var isPinned: Bool { panel.isPinned }
    var isShowingActions: Bool { panel.isShowingActions }
    /// The window's actual current on-screen bottom-center (tracks user drags),
    /// used for stacking/overlap decisions.
    var currentBottomCenter: CGPoint { panel.frameBottomCenter }

    // MARK: - Show / recycle (transient window)

    /// Update the captured selection text in place WITHOUT a hide/reposition —
    /// used for an in-place refresh (double→triple-click growing the same
    /// selection). The window doesn't move, so its placement is untouched.
    func refreshSelection(text: String) {
        self.text = text
    }

    /// Show (or recycle) this window's capsule in its `.actions` phase, anchored at
    /// `anchor`, acting on `text`. Bumps the panel generation and cancels any prior
    /// in-flight action in THIS window so its stale tokens can't bleed into the new
    /// popup.
    func show(text: String, anchor: CGPoint, actions: [PopBarActionConfig]) {
        self.text = text
        panelGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        panel.model.actions = actions
        panel.show(at: anchor)
    }

    /// Hide & tear down this window's content. Bumps the panel generation so any
    /// in-flight action result is discarded rather than re-showing a dismissed
    /// popup, and cancels this window's stream.
    func hide() {
        panelGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        panel.hide()
    }

    /// Cancel any in-flight stream and bump generations so nothing can apply onto
    /// this window after it's released. Used when a pinned window closes.
    func teardown() {
        panelGeneration &+= 1
        actionGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
    }

    func setAutoExpandHeight(_ on: Bool) {
        panel.setAutoExpandHeight(on)
    }

    func setResultFontSize(_ size: Double) {
        panel.setResultFontSize(size)
    }

    // MARK: - Actions (self-contained per window)

    /// Run a tapped action inside THIS window, streaming into THIS window's panel.
    /// All generation/cancellation is local to the session, so a stream here is
    /// never cancelled by a selection or action in another window.
    func runAction(_ action: PopBarActionConfig) {
        let text = self.text
        let generation = panelGeneration
        actionTask?.cancel()   // a tap replaces any prior in-flight action in THIS window
        actionGeneration &+= 1
        let action0 = actionGeneration
        // A run is current only if BOTH the panel hasn't been replaced/dismissed
        // AND no newer action was tapped on this same capsule.
        func isCurrent(_ session: PopBarSession) -> Bool {
            generation == session.panelGeneration && action0 == session.actionGeneration
        }

        guard action.isAI else {
            // Local actions (copy) have no loading/result UI — run and apply.
            actionTask = Task { [weak self] in
                let outcome = await ActionRegistry.run(action, on: text, llm: nil)
                await MainActor.run {
                    guard let self, isCurrent(self) else { return }
                    self.applyOutcome(outcome)
                }
            }
            return
        }

        // AI: show the result chrome IMMEDIATELY (empty → placeholder), then stream
        // tokens into it. No `.loading` blocking state; the window is up at once.
        let llm = llmStore.config(for: action.modelOverride)
        panel.applyPhase(.result(""))
        actionTask = Task { [weak self] in
            let outcome = await ActionRegistry.runStreaming(action, on: text, llm: llm) { displayed in
                // Every delta hops to main and bails if a newer popup OR a newer
                // action on this same capsule took over, so stale tokens never leak.
                Task { @MainActor [weak self] in
                    guard let self, isCurrent(self) else { return }
                    self.panel.updateResultText(displayed)
                }
            }
            await MainActor.run {
                guard let self, isCurrent(self) else { return }
                // The per-delta `Task { @MainActor }` updates above aren't ordered
                // relative to this final apply, so a straggler could otherwise land
                // AFTER it and revert the text to an earlier partial. Bump the token
                // FIRST: any delta still queued now fails `isCurrent` and is dropped,
                // then apply the canonical final outcome.
                self.actionGeneration &+= 1
                self.applyOutcome(outcome)
            }
        }
    }

    /// What the session does when an action finishes. `.dismiss` is reported to the
    /// owner (the manager) so a transient window auto-closes while a pinned window's
    /// close is driven only by its own close button.
    var onDismissOutcome: (() -> Void)?

    private func applyOutcome(_ outcome: PopBarActionOutcome) {
        switch outcome {
        case .dismiss:                 onDismissOutcome?()
        case .showResult(let output):  panel.applyPhase(.result(output))
        }
    }

    /// Copy this window's current result to the pasteboard (the chrome copy button).
    func copyResult(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
