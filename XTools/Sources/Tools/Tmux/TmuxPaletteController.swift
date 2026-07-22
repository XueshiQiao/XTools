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

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = TmuxPaletteRootView(
            store: store,
            onClose: { [weak self] in self?.hide(restoreFocus: true) }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true

        // Borderless floating glass panel — same recipe as PopBar (no traffic
        // lights, no title bar, clear + material fill in the SwiftUI root).
        let panel = NSPanel(
            contentRect: Self.centeredFrame(),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 280, height: 280)
        panel.delegate = self

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

// MARK: - Palette root (tree only + liquid glass + Esc)

/// Shell-free host: only the tree, on a PopBar-style visual-effect glass plate.
private struct TmuxPaletteRootView: View {
    @ObservedObject var store: TmuxStore
    let onClose: () -> Void

    private let cornerRadius: CGFloat = 16

    var body: some View {
        TmuxPaletteTreeView(store: store)
            .frame(minWidth: 280, minHeight: 280)
            .background(VisualEffectBlur(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
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
