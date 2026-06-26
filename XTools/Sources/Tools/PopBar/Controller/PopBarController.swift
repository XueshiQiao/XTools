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

    /// The text the visible capsule is acting on.
    private var currentText = ""
    private var running = false
    private var resolveTask: Task<Void, Never>?
    /// Bumped per trigger so a slow/canceled resolve can't act on the panel after
    /// a newer trigger has taken over.
    private var resolveGeneration = 0

    init() {
        resolver = SelectionResolver(strategies: [
            AccessibilityStrategy(),   // fast, side-effect-free; preferred
            ClipboardCopyStrategy(),   // fallback for browsers / Electron / custom views
        ])
        monitor = GlobalInputMonitor(gestures: [
            DragSelectGesture(),
            DoubleClickGesture(),
        ])
        monitor.onTrigger = { [weak self] in self?.handleTrigger() }
        monitor.onDismiss = { [weak self] in self?.handleDismiss() }
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
        panel.hide()
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
                guard self.running, let result, !result.text.isEmpty else { self.panel.hide(); return }
                self.currentText = result.text
                self.panel.show(at: context.mouseLocation)
            }
        }
    }

    private func handleDismiss() {
        if panel.isVisible { panel.hide() }
    }

    // MARK: - Actions

    private func wirePanel() {
        panel.model.onAction = { [weak self] action in self?.runAction(action) }
        panel.model.onCopyResult = { [weak self] text in self?.copyToPasteboard(text); self?.panel.hide() }
        panel.model.onClose = { [weak self] in self?.panel.hide() }
    }

    private func runAction(_ action: PopBarAction) {
        let text = currentText
        switch action.kind {
        case .copy:
            Task { [weak self] in
                _ = await ActionRegistry.run(action, on: text)
                await MainActor.run { self?.panel.hide() }
            }
        case .aiTransform:
            panel.applyPhase(.loading)
            Task { [weak self] in
                let outcome = await ActionRegistry.run(action, on: text)
                await MainActor.run {
                    guard let self else { return }
                    if case .showResult(let output) = outcome {
                        self.panel.applyPhase(.result(output))
                    } else {
                        self.panel.hide()
                    }
                }
            }
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
        currentText = L("popbar.preview.sample")
        panel.show(at: CGPoint(x: frame.midX, y: frame.midY))
        Self.log.info("showing preview capsule")
    }
}
