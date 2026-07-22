import AppKit
import SwiftUI
import Combine

/// App-lifetime controller: registers the global hotkey and owns the floating
/// palette window that hosts a shell-free `TmuxView`.
///
/// Main-thread only by convention (hotkey callback + all window work).
final class TmuxPaletteController: NSObject, ObservableObject, NSWindowDelegate {

    private static let log = FileLog("Tmux.Palette")
    private static let defaultSize = NSSize(width: 440, height: 600)

    // MARK: Background style
    //
    // Why PopBar-style `behindWindow` blur felt terrible here but fine on the
    // capsule: PopBar is ~260×64. This palette is ~440×600 and *scrolls*.
    // `NSVisualEffectView.blendingMode = .behindWindow` re-samples the live
    // desktop under the whole window every composite frame — fine for a tiny
    // HUD, catastrophic under a scrolling list or while dragging the window.
    // Full-screen "translucent" UIs usually don't do that (they use Metal, a
    // static wallpaper capture, or blur only *within* the window).
    //
    // Recipe we use now: clear borderless panel + SwiftUI `Material` fill.
    // Material is an in-window frosted plate — translucency look without live
    // desktop sampling on every scroll.

    private let store: TmuxStore
    private var hotKey: GlobalHotKey?
    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?

    /// Mirrors prefs for the settings UI.
    @Published var hotkeyEnabled: Bool
    @Published var hotKeyCombo: KeyCombo
    /// True when the Carbon registration is live.
    @Published private(set) var isRegistered = false
    /// Set when the last enable/setHotKey attempt failed (combo taken).
    @Published var hotkeyOccupied = false

    init(store: TmuxStore) {
        self.store = store
        self.hotkeyEnabled = TmuxPreferences.hotkeyEnabled
        self.hotKeyCombo = TmuxPreferences.hotKey
        super.init()
        // Jump success → dismiss palette so the user lands back in the terminal.
        store.onJumpSucceeded = { [weak self] in
            self?.hide(restoreFocus: true)
        }
    }

    // MARK: - Lifecycle

    /// Register the hotkey if the user has it enabled (called from `TmuxTool.activate`).
    func startIfEnabled() {
        guard TmuxPreferences.hotkeyEnabled else {
            Self.log.info("palette hotkey disabled — not registering")
            isRegistered = false
            return
        }
        _ = registerHotKey()
    }

    func stop() {
        hide(restoreFocus: false)
        invalidateHotKey()
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    // MARK: - Prefs mutations (settings UI)

    /// Enable/disable and (re)register. Returns false if enabling failed (combo taken).
    @discardableResult
    func setHotkeyEnabled(_ enabled: Bool) -> Bool {
        hotkeyEnabled = enabled
        TmuxPreferences.hotkeyEnabled = enabled
        if enabled {
            let ok = registerHotKey()
            hotkeyOccupied = !ok
            return ok
        } else {
            invalidateHotKey()
            hotkeyOccupied = false
            return true
        }
    }

    /// Persist + re-register a new combo. On failure keeps the previous registration.
    @discardableResult
    func setHotKey(_ combo: KeyCombo) -> Bool {
        guard TmuxPreferences.hotkeyEnabled || hotkeyEnabled else {
            hotKeyCombo = combo
            TmuxPreferences.hotKey = combo
            return true
        }
        let previous = hotKeyCombo
        invalidateHotKey()
        hotKeyCombo = combo
        if registerHotKey() {
            TmuxPreferences.hotKey = combo
            hotkeyOccupied = false
            return true
        }
        // Revert.
        Self.log.warn("failed to register \(combo.display) — reverting to \(previous.display)")
        hotKeyCombo = previous
        _ = registerHotKey()
        hotkeyOccupied = true
        return false
    }

    // MARK: - Show / hide

    func toggle() {
        if panel?.isVisible == true {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        store.refresh()
        let panel = ensurePanel()
        if panel.frame.width < 80 || panel.frame.height < 80 {
            panel.setFrame(Self.centeredFrame(), display: false)
        }
        // Activate so search field / list get key focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Self.log.info("palette shown")
    }

    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible else {
            if restoreFocus { previousApp?.activate() }
            return
        }
        TmuxPreferences.windowFrame = panel.frame
        panel.orderOut(nil)
        Self.log.info("palette hidden")
        if restoreFocus {
            // Give the previous app a tick so orderOut settles first.
            let app = previousApp
            DispatchQueue.main.async {
                app?.activate()
            }
        }
    }

    // MARK: - Hotkey registration

    @discardableResult
    private func registerHotKey() -> Bool {
        invalidateHotKey()
        let combo = hotKeyCombo
        hotKey = GlobalHotKey(combo: combo) { [weak self] in
            self?.toggle()
        }
        isRegistered = hotKey != nil
        if isRegistered {
            Self.log.info("palette hotkey registered: \(combo.display)")
        } else {
            Self.log.warn("palette hotkey failed: \(combo.display)")
        }
        return isRegistered
    }

    private func invalidateHotKey() {
        hotKey?.invalidate()
        hotKey = nil
        isRegistered = false
    }

    // MARK: - Panel
    //
    // Why rounded corners kept "disappearing" when we fixed lag
    // ---------------------------------------------------------
    // macOS has two different notions of "round":
    //
    // 1) **Window silhouette** (what you see against the desktop)
    // 2) **View layer cornerRadius** (clips content *inside* the window)
    //
    // An **opaque** window must fill every pixel of its rectangular frame
    // (`isOpaque = true`). If you only set `layer.cornerRadius` on the content
    // view, the clipped corners still sit on top of the same opaque window
    // background → silhouette stays a rectangle → "round corners vanished".
    //
    // True rounded silhouette with transparent corner pixels requires
    // `isOpaque = false` (or live glass). That is the path that lagged for us.
    //
    // Best practice on modern macOS (Big Sur+): use a **normal titled window**.
    // The window server draws the system rounded shape while the surface stays
    // fully opaque — same recipe as System Settings / most floating tools.
    // Hide the traffic lights if you want a chrome-light look; keep the style
    // mask that participates in the system shape.

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = TmuxPaletteRootView(
            store: store,
            onClose: { [weak self] in self?.hide(restoreFocus: true) }
        )
        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: Self.centeredFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Opaque solid — no desktop sampling (the lag root cause).
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true

        // Keep the system title bar (rounded silhouette + drag chrome). Show a
        // real title; leave traffic lights visible so the bar is a normal window.
        panel.title = L("tool.tmux.title")
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        // No manual layer.cornerRadius — that only fakes inner clip and fights
        // the opaque fill (looks square). System shape owns the silhouette.
        panel.minSize = NSSize(width: 280, height: 280)
        panel.delegate = self
        Self.log.info("palette panel created (opaque + system rounded titled shape)")

        if let saved = TmuxPreferences.windowFrame {
            panel.setFrame(saved, display: false)
        }

        self.panel = panel
        return panel
    }

    private static func centeredFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = defaultSize
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let panel {
            TmuxPreferences.windowFrame = panel.frame
        }
        // Red traffic-light close: restore previous app focus.
        let app = previousApp
        DispatchQueue.main.async { app?.activate() }
    }

    func windowDidResize(_ notification: Notification) {
        if let panel, panel.isVisible {
            TmuxPreferences.windowFrame = panel.frame
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let panel, panel.isVisible {
            TmuxPreferences.windowFrame = panel.frame
        }
    }
}

// MARK: - Palette root (tree only + Esc)

/// Shell-free host. Same opaque aurora wash as the main window (`auroraBackground`)
/// — soft gradient on a solid base, no live desktop sampling.
/// Corners are rounded on the hosting view layer in `ensurePanel()`.
private struct TmuxPaletteRootView: View {
    @ObservedObject var store: TmuxStore
    let onClose: () -> Void

    var body: some View {
        TmuxPaletteTreeView(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 280, minHeight: 280)
            .auroraBackground()
            .onExitCommand(perform: onClose)
            .background(EscKeyMonitor(onEsc: onClose))
    }
}

/// Local key monitor that fires on bare Esc while the palette is key.
private struct EscKeyMonitor: NSViewRepresentable {
    let onEsc: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onEsc = onEsc
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEsc = onEsc
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onEsc: (() -> Void)?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Bare Esc (keyCode 53).
                if event.keyCode == 53 && event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask).isEmpty {
                    self?.onEsc?()
                    return nil
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
