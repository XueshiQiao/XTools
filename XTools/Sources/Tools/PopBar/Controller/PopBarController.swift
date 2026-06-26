import AppKit

/// The app-lifetime coordinator that wires the four layers together: it listens
/// for selection gestures (trigger), resolves the selected text (selection),
/// shows the capsule (window), and runs the tapped action (action).
///
/// Main-thread only by convention (like `GuardianReaper`): `NSEvent` monitor
/// callbacks, SwiftUI callbacks, and `activate()` all arrive on main. The one
/// piece that runs off-main is the resolver `Task`, which hops back to main
/// before touching any window.
final class PopBarController {

    private static let log = FileLog("PopBar")

    private let resolver: SelectionResolver
    private let monitor: GlobalInputMonitor
    private let panel = PopBarPanel()
    private let llmStore: PopBarLLMStore
    private let actionStore: ActionStore

    /// The text the visible capsule is acting on.
    private var currentText = ""
    /// Screen point the visible capsule is anchored to (the selection's mouse-up
    /// location), used to suppress flicker from a double→triple-click re-trigger.
    private var lastAnchor: CGPoint = .zero
    /// How close a new trigger must be to the current capsule to be treated as
    /// the same selection (keep it, don't re-read/re-show).
    private let sameSelectionRadius: CGFloat = 40
    private var running = false
    private var resolveTask: Task<Void, Never>?
    /// The in-flight AI action (streaming). Canceled when a new action/trigger
    /// starts or the panel is dismissed, so old tokens never bleed into a new popup.
    private var actionTask: Task<Void, Never>?
    /// Bumped on every action run. A second action tapped on the SAME visible
    /// capsule (so `panelGeneration` is unchanged) must not have the prior stream's
    /// already-enqueued MainActor delta tasks overwrite the new result — they check
    /// this token too and bail.
    private var actionGeneration = 0
    /// Bumped per trigger so a slow/canceled resolve can't act on the panel after
    /// a newer trigger has taken over.
    private var resolveGeneration = 0
    /// Bumped on every panel show/hide so a slow AI action can't apply its result
    /// onto a capsule that has since been replaced or dismissed.
    private var panelGeneration = 0

    init(llmStore: PopBarLLMStore, actionStore: ActionStore) {
        self.llmStore = llmStore
        self.actionStore = actionStore
        resolver = SelectionResolver(strategies: [
            AccessibilityStrategy(),   // fast, side-effect-free; preferred
            ClipboardCopyStrategy(),   // fallback for browsers / Electron / custom views
        ])
        monitor = GlobalInputMonitor(gestures: [
            DragSelectGesture(),
            DoubleClickGesture(),
        ])
        monitor.onTrigger = { [weak self] in self?.handleTrigger() }
        monitor.onDismiss = { [weak self] event in self?.handleDismiss(event) }
        wirePanel()
    }

    var isRunning: Bool { running }

    // MARK: - Lifecycle (call on main)

    /// Start only if the user has opted in (used at app launch).
    func startIfEnabled() {
        guard PopBarPreferences.isEnabled else { Self.log.info("disabled — not starting"); return }
        start()
    }

    /// Start global monitoring. No-op without the Accessibility permission.
    func start() {
        guard !running else { return }
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.warn("no Accessibility permission — not starting")
            return
        }
        running = true
        monitor.start()
        Self.log.info("started")
    }

    func stop() {
        running = false
        resolveTask?.cancel()
        actionTask?.cancel()
        monitor.stop()
        hidePanel()
        Self.log.info("stopped")
    }

    // MARK: - Trigger → resolve → show

    private func handleTrigger() {
        // A pinned capsule stays put — don't replace it on a new selection.
        if panel.isPinned { return }

        // `frontmostApplication` can momentarily return nil; fall back to the
        // menu-bar-owning app so the Electron AX-enable + self-skip still work.
        let front = NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.menuBarOwningApplication
        // Never read our own UI.
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let loc = monitor.lastMouseUpLocation
        // Same spot + the capsule already showing its actions → this is a re-trigger
        // for the SAME selection growing (e.g. double-click then triple-click). We
        // re-read so the action uses the LATEST selection (the whole line), but we
        // update the captured text *in place* — no hide/reposition — so the window
        // stays put and doesn't flicker.
        let inPlace = panel.isVisible && panel.isShowingActions
            && hypot(loc.x - lastAnchor.x, loc.y - lastAnchor.y) < sameSelectionRadius

        let context = SelectionContext(frontmostApp: front, mouseLocation: loc)
        Self.log.debug("trigger — front=\(front?.bundleIdentifier ?? front?.localizedName ?? "nil") inPlace=\(inPlace)")

        resolveTask?.cancel()
        resolveGeneration &+= 1
        let generation = resolveGeneration
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.resolver.resolve(context)
            if Task.isCancelled { return }
            await MainActor.run {
                guard generation == self.resolveGeneration, self.running else { return }
                guard let result, !result.text.isEmpty else {
                    if !inPlace { self.hidePanel() }   // don't tear down on an in-place refresh miss
                    return
                }
                if inPlace {
                    // Only refresh if still showing actions at the same spot.
                    guard self.panel.isShowingActions else { return }
                    self.currentText = result.text
                    self.lastAnchor = loc
                } else {
                    self.currentText = result.text
                    self.lastAnchor = loc
                    self.panelGeneration &+= 1
                    self.actionTask?.cancel()   // abort any prior AI stream
                    self.actionTask = nil
                    self.panel.model.actions = self.actionStore.actions
                    self.panel.show(at: loc)
                }
            }
        }
    }

    private func handleDismiss(_ event: InputEvent) {
        guard panel.isVisible, !panel.isPinned else { return }
        // A multi-click continuation (e.g. double-click then an accidental triple)
        // shouldn't dismiss — that would hide then immediately reshow (flicker).
        if case let .mouseDown(nsEvent) = event, nsEvent.clickCount >= 2 { return }
        hidePanel()
    }

    /// Hide the capsule and bump the panel generation so any in-flight action
    /// result is discarded rather than re-showing a dismissed popup.
    private func hidePanel() {
        panelGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        panel.hide()
    }

    // MARK: - Actions

    private func wirePanel() {
        panel.model.onAction = { [weak self] action in self?.runAction(action) }
        panel.model.onCopyResult = { [weak self] text in self?.copyToPasteboard(text); self?.hidePanel() }
        panel.model.onClose = { [weak self] in self?.hidePanel() }
        panel.model.onTogglePin = { [weak self] in
            guard let self else { return }
            self.panel.setPinned(!self.panel.isPinned)
        }
    }

    private func runAction(_ action: PopBarActionConfig) {
        let text = currentText
        let generation = panelGeneration
        actionTask?.cancel()   // a tap replaces any prior in-flight action
        actionGeneration &+= 1
        let action0 = actionGeneration
        // A run is current only if BOTH the panel hasn't been replaced/dismissed
        // AND no newer action was tapped on this same capsule.
        func isCurrent(_ controller: PopBarController) -> Bool {
            generation == controller.panelGeneration && action0 == controller.actionGeneration
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

    private func applyOutcome(_ outcome: PopBarActionOutcome) {
        switch outcome {
        case .dismiss:                 hidePanel()
        case .showResult(let output):  panel.applyPhase(.result(output))
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Preview (verification affordance)

    /// Show the capsule at screen center with sample text — used by the settings
    /// "Preview" button and by `XTOOLS_POPBAR_PREVIEW=1` at launch. Lets the UI
    /// be seen without performing a real system-wide selection.
    func showPreview() {
        let frame = NSScreen.main?.frame ?? .zero
        let center = CGPoint(x: frame.midX, y: frame.midY)
        currentText = L("popbar.preview.sample")
        lastAnchor = center
        panelGeneration &+= 1
        panel.model.actions = actionStore.actions
        panel.show(at: center)
        Self.log.info("showing preview capsule")
    }

    /// Push a live auto-expand preference change (from settings) onto the panel so
    /// an already-open result honors it without waiting for the next popup.
    func setAutoExpandHeight(_ on: Bool) {
        panel.setAutoExpandHeight(on)
    }
}
