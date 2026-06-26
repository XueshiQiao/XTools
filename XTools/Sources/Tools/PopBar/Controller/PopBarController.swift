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
        monitor.stop()
        hidePanel()
        Self.log.info("stopped")
    }

    // MARK: - Trigger → resolve → show

    private func handleTrigger() {
        // A pinned capsule stays put — don't replace it on a new selection.
        if panel.isPinned { return }
        // If a capsule is already showing for ~this spot, keep it exactly as is.
        // A double-click then an accidental triple-click fire two triggers at the
        // same point; without this they'd hide+re-resolve+reshow (flicker). Per
        // the user, the existing result is fine — no need to re-read the range.
        let loc = monitor.lastMouseUpLocation
        if panel.isVisible,
           hypot(loc.x - lastAnchor.x, loc.y - lastAnchor.y) < sameSelectionRadius {
            return
        }
        // `frontmostApplication` can momentarily return nil; fall back to the
        // menu-bar-owning app so the Electron AX-enable + self-skip still work.
        let front = NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.menuBarOwningApplication
        // Never read our own UI.
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let context = SelectionContext(frontmostApp: front, mouseLocation: monitor.lastMouseUpLocation)
        Self.log.debug("trigger — front=\(front?.bundleIdentifier ?? front?.localizedName ?? "nil") at \(context.mouseLocation)")

        resolveTask?.cancel()
        resolveGeneration &+= 1
        let generation = resolveGeneration
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.resolver.resolve(context)
            if Task.isCancelled { return }
            await MainActor.run {
                // A newer trigger superseded this one — let it own the panel.
                guard generation == self.resolveGeneration else { return }
                guard self.running, let result, !result.text.isEmpty else { self.hidePanel(); return }
                self.currentText = result.text
                self.lastAnchor = context.mouseLocation
                self.panelGeneration &+= 1
                self.panel.model.actions = self.actionStore.actions
                self.panel.show(at: context.mouseLocation)
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
        // AI actions need a model config + a loading state; local actions don't.
        let llm: LLMConfig?
        if action.isAI {
            panel.applyPhase(.loading)
            llm = llmStore.config(for: action.modelOverride)
        } else {
            llm = nil
        }
        let generation = panelGeneration
        Task { [weak self] in
            let outcome = await ActionRegistry.run(action, on: text, llm: llm)
            await MainActor.run {
                guard let self, generation == self.panelGeneration else { return }
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
}
