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

    private let llm: LLMService

    /// The text the visible capsule is acting on (this window's selection).
    private(set) var text = ""
    /// The link associated with this window's selection, resolved at trigger time by
    /// `LinkResolver` (nil if none / no web-preview action on the wheel). Consumed by
    /// the web-preview action when tapped.
    private(set) var url: URL?

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

    init(llm: LLMService) {
        self.llm = llm
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
    func refreshSelection(text: String, url: URL?) {
        self.text = text
        self.url = url
    }

    /// Show (or recycle) this window's capsule in its `.actions` phase, anchored at
    /// `anchor`, acting on `text`. Bumps the panel generation and cancels any prior
    /// in-flight action in THIS window so its stale tokens can't bleed into the new
    /// popup.
    func show(text: String, url: URL?, anchor: CGPoint, actions: [PopBarActionConfig]) {
        self.text = text
        self.url = url
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

    func setWheelLayout(_ layout: WheelLayout) {
        panel.setWheelLayout(layout)
    }

    // MARK: - Actions (self-contained per window)

    /// Run a tapped action inside THIS window, streaming into THIS window's panel.
    /// All generation/cancellation is local to the session, so a stream here is
    /// never cancelled by a selection or action in another window.
    func runAction(_ action: PopBarActionConfig) {
        let text = self.text
        let url = self.url
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
            // Local actions (copy / web preview) have no loading/result chrome — run
            // and present. Web preview opens the mini-browser window (via `present`).
            actionTask = Task { [weak self] in
                let outcome = await ActionRegistry.run(action, on: text, url: url, service: nil, config: nil)
                await MainActor.run {
                    guard let self, isCurrent(self) else { return }
                    self.present(outcome)
                }
            }
            return
        }

        // AI: show the result chrome IMMEDIATELY (empty → placeholder), then stream
        // tokens into it. No `.loading` blocking state; the window is up at once.
        // Resolve the config (default or per-action override) from the shared service.
        let config = resolveConfig(for: action.modelOverride)
        let service = self.llm
        panel.applyPhase(.result(""))
        actionTask = Task { [weak self] in
            let outcome = await ActionRegistry.runStreaming(action, on: text, url: url, service: service, config: config) { displayed in
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
                self.present(outcome)
            }
        }
    }

    /// Resolve the LLM config for an action's optional override via the shared
    /// service: an override names provider/model/effort (key resolved per-provider);
    /// no override → the app-wide default. nil when the resolved provider has no key
    /// (and isn't Ollama), so the action shows a "set a key" message.
    private func resolveConfig(for override: ModelOverride?) -> LLMConfig? {
        if let o = override {
            return llm.config(forProvider: o.provider, model: o.model, effort: o.reasoningEffort)
        }
        return llm.defaultConfig()
    }

    /// What the session does when an action finishes with `.none` (e.g. Copy) or opens
    /// a web preview. Reported to the owner (the manager) so a transient window
    /// auto-closes while a pinned window's close is driven only by its own close button.
    var onDismissOutcome: (() -> Void)?
    /// Open the resolved link in the shared mini-browser. Wired by the manager.
    var onWebPreview: ((URL) -> Void)?
    /// Open the resolved local file in the shared Quick Look window. Wired by the
    /// manager (which owns that window); Finder needs no such hand-off, since it
    /// isn't a window we own.
    var onQuickLook: ((URL) -> Void)?

    /// Route a presentation to its surface — the single place output types map to UI.
    /// Adding a new `PopBarPresentation` case means adding one branch here.
    private func present(_ presentation: PopBarPresentation) {
        switch presentation {
        case .none:
            onDismissOutcome?()
        case .result(let output):
            panel.applyPhase(.result(output))
        case .webPreview(let url):
            // Open the mini-browser, then dismiss this popup (the user's attention
            // moves to the preview window, same one-shot feel as Copy) — but NEVER a
            // pinned window: only transients auto-dismiss, so a pinned popup keeps its
            // content when its web-preview action is used.
            onWebPreview?(url)
            if !isPinned { onDismissOutcome?() }
        case .quickLook(let url):
            // Same one-shot feel as the web preview: attention moves to the preview
            // window, so a transient popup steps aside and a pinned one stays put.
            onQuickLook?(url)
            if !isPinned { onDismissOutcome?() }
        case .revealInFinder(let url, let isDirectory):
            // Dismiss FIRST, then hand off to Finder: ordering our panel out after
            // Finder came forward can pull the focus straight back to us.
            if !isPinned { onDismissOutcome?() }
            revealInFinder(url, isDirectory: isDirectory)
        }
    }

    /// Show a path in Finder — a folder opens in place, a file is revealed and
    /// selected in its parent — and make sure Finder actually comes to the FRONT.
    ///
    /// Neither `open(_:)` nor `activateFileViewerSelecting(_:)` promises to raise
    /// the app: they only ask Finder to open/scroll to a window. We are an
    /// `LSUIElement` app that has typically just called `NSApp.activate` for the
    /// popup, so without the explicit activation below Finder opens the window
    /// *behind* everything and the action looks like it silently did nothing.
    private func revealInFinder(_ url: URL, isDirectory: Bool) {
        // Raising Finder is done by NSWorkspace, NOT by `NSRunningApplication
        // .activate()`. That call is REFUSED here — it returns false and Finder
        // opens behind whatever is in front. Measured, not guessed: the identical
        // call in a stripped-down test app returns true and raises Finder when the
        // process is `.accessory`, and returns false when it is `.regular` — and
        // `AppDelegate` promotes XTools to `.regular` at launch so it gets a Dock
        // icon and a menu bar.
        //
        // `open(_:configuration:)` with `activates` goes through the system
        // instead of asking for the front slot ourselves, so the policy does not
        // gate it. The folder to show is the item itself, or the file's parent.
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(folder, configuration: config) { [weak self] app, error in
            guard let self else { return }
            if let error {
                Self.log.error("reveal: opening the folder failed — \(error.localizedDescription)")
                return
            }
            Self.log.info("reveal: Finder up (\(app?.bundleIdentifier ?? "nil")), isDirectory=\(isDirectory)")
            // Select the file only once Finder is frontmost, so the selection
            // lands in the window that was just brought forward.
            guard !isDirectory else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Copy this window's current result to the pasteboard (the chrome copy button).
    func copyResult(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
