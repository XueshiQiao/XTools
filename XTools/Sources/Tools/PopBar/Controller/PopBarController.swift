import AppKit

/// The app-lifetime coordinator that wires the layers together: it listens for
/// selection gestures (trigger), resolves the selected text (selection), and asks
/// the window manager to show / recycle the capsule. Per-window concerns (which
/// windows exist, pin promotion, each window's action/stream lifecycle) live in
/// `PopBarWindowManager` + `PopBarSession`, so multiple pinned windows can coexist
/// and a new selection never disturbs a pinned window (issue #13).
///
/// Main-thread only by convention (like `GuardianReaper`): `NSEvent` monitor
/// callbacks, SwiftUI callbacks, and `activate()` all arrive on main. The one
/// piece that runs off-main is the resolver `Task`, which hops back to main
/// before touching any window.
final class PopBarController {

    private static let log = FileLog("PopBar")

    private let resolver: SelectionResolver
    private let monitor: GlobalInputMonitor
    private let windows: PopBarWindowManager
    private let llmStore: PopBarLLMStore
    private let actionStore: ActionStore

    /// Screen point the transient capsule's CURRENT selection is anchored to (the
    /// selection's raw mouse-up location), used to suppress flicker from a
    /// double→triple-click re-trigger. Kept here (not on the window) because the
    /// window's own anchor may be offset to avoid overlapping a pinned window.
    private var lastAnchor: CGPoint = .zero
    /// How close a new trigger must be to the current capsule to be treated as
    /// the same selection (keep it, don't re-read/re-show).
    private let sameSelectionRadius: CGFloat = 40
    private var running = false
    private var resolveTask: Task<Void, Never>?
    /// Bumped per trigger so a slow/canceled resolve can't act on the panel after
    /// a newer trigger has taken over.
    private var resolveGeneration = 0

    init(llmStore: PopBarLLMStore, actionStore: ActionStore) {
        self.llmStore = llmStore
        self.actionStore = actionStore
        self.windows = PopBarWindowManager(llmStore: llmStore)
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
        windows.closeAll()
        Self.log.info("stopped")
    }

    // MARK: - Trigger → resolve → show

    private func handleTrigger() {
        // `frontmostApplication` can momentarily return nil; fall back to the
        // menu-bar-owning app so the Electron AX-enable + self-skip still work.
        let front = NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.menuBarOwningApplication
        // Never read our own UI.
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let loc = monitor.lastMouseUpLocation
        // Same spot + the transient already showing its actions → this is a
        // re-trigger for the SAME selection growing (e.g. double-click then triple-
        // click). We re-read so the action uses the LATEST selection (the whole
        // line), but we update the captured text *in place* — no hide/reposition —
        // so the window stays put and doesn't flicker. Pinned windows are never the
        // target of a re-trigger; the transient is.
        let inPlace = windows.transientIsShowingActions
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
                    if !inPlace { self.windows.dismissTransient() }   // don't tear down on an in-place refresh miss
                    return
                }
                if inPlace {
                    // Only refresh the captured text; the window doesn't move, so
                    // its placed anchor stays put. `lastAnchor` still tracks the raw
                    // selection location for the NEXT re-trigger's proximity check.
                    self.lastAnchor = loc
                    self.windows.refreshTransientSelection(text: result.text)
                } else {
                    self.lastAnchor = loc
                    self.windows.showTransient(text: result.text, anchor: loc, actions: self.actionStore.actions)
                }
            }
        }
    }

    private func handleDismiss(_ event: InputEvent) {
        // Only the transient (unpinned) window auto-dismisses; pinned windows
        // persist until their own close button.
        guard windows.transientIsVisibleUnpinned else { return }
        // A multi-click continuation (e.g. double-click then an accidental triple)
        // shouldn't dismiss — that would hide then immediately reshow (flicker).
        if case let .mouseDown(nsEvent) = event, nsEvent.clickCount >= 2 { return }
        windows.dismissTransient()
    }

    // MARK: - Preview (verification affordance)

    /// Show the capsule at screen center with sample text — used by the settings
    /// "Preview" button and by `XTOOLS_POPBAR_PREVIEW=1` at launch. Lets the UI
    /// be seen without performing a real system-wide selection.
    func showPreview() {
        let frame = NSScreen.main?.frame ?? .zero
        let center = CGPoint(x: frame.midX, y: frame.midY)
        lastAnchor = center
        windows.showTransient(text: L("popbar.preview.sample"), anchor: center, actions: actionStore.actions)
        Self.log.info("showing preview capsule")
    }

    /// Push a live auto-expand preference change (from settings) onto every open
    /// window so an already-open result honors it without waiting for the next popup.
    func setAutoExpandHeight(_ on: Bool) {
        windows.setAutoExpandHeight(on)
    }
}
