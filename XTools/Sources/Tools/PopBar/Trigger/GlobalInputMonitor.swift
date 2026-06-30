import AppKit

/// The trigger layer's engine. Installs a single **global** `NSEvent` monitor,
/// normalizes events, broadcasts them to the gesture recognizers, and reports:
///  - `onTrigger` — a selection gesture completed (after a short debounce);
///  - `onDismiss` — a mouse-down / scroll / key-down happened elsewhere (used to
///    close an open popup).
///
/// Deliberately **global-only**. A global monitor observes events delivered to
/// *other* apps and can't consume them (exactly what we want — we never disturb
/// the user's input). Crucially, it does NOT see clicks on our own
/// non-activating panel, so wiring dismiss-on-mousedown here can't race a button
/// tap on the popup itself. We avoid `CGEventTap` on purpose: it can be silently
/// disabled by the system and is far less robust for passive observation.
final class GlobalInputMonitor {

    private static let log = FileLog("PopBar.Monitor")

    private let gestures: [SelectionGesture]
    private let debounce: TimeInterval
    private var globalMonitor: Any?
    /// Trailing-edge debounce: the pending (not-yet-fired) trigger. A new gesture
    /// firing cancels and reschedules it, so a rapid multi-click (double→triple, which
    /// fires the click gesture on BOTH the 2nd and 3rd mouse-down) collapses into a
    /// SINGLE `onTrigger` after the last click. This matters for the clipboard-⌘C
    /// selection path: without it, the earlier click's resolve injects a synthetic ⌘C
    /// mid-multi-click and disrupts the app's own selection (apps whose selection is
    /// AX-readable don't show this, since their resolve is a side-effect-free AX read).
    private var pendingTrigger: DispatchWorkItem?

    /// Fired (on main) after a gesture completes and the debounce elapses.
    var onTrigger: (() -> Void)?
    /// Fired (on main) for events that may dismiss an open popup. Carries the
    /// event so the controller can ignore multi-click continuations.
    var onDismiss: ((InputEvent) -> Void)?

    /// Screen-coordinate location of the last mouse-up — where the gesture ended.
    private(set) var lastMouseUpLocation: CGPoint = .zero

    /// `NSPasteboard.general.changeCount` sampled at the most recent mouse-DOWN,
    /// i.e. the baseline at each gesture's start. The controller reads this when
    /// building the `SelectionContext` so a strategy can tell whether the clipboard
    /// changed *during* the gesture (an app's "copy on select"). Sampled on main
    /// (NSEvent monitors fire on main), so the read is cheap and thread-safe.
    private(set) var gestureStartClipboardChangeCount: Int = NSPasteboard.general.changeCount

    init(gestures: [SelectionGesture], debounce: TimeInterval = 0.1) {
        self.gestures = gestures
        self.debounce = debounce
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        Self.log.info("started global input monitor")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        pendingTrigger?.cancel()
        pendingTrigger = nil
        Self.log.info("stopped global input monitor")
    }

    deinit { stop() }

    // MARK: - Event handling (main thread — NSEvent monitors fire on main)

    private func handle(_ event: NSEvent) {
        // Ignore the synthetic ⌘C we post ourselves (the clipboard-copy fallback): it
        // arrives here as a real keyDown, and treating it as user input would dismiss
        // the popup we're in the middle of showing (the triple-click "pop then vanish"
        // in AX-opaque apps). Tagged in `KeySender`.
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == KeySender.syntheticUserData {
            return
        }

        let input: InputEvent
        switch event.type {
        case .leftMouseDown:
            input = .mouseDown(event)
            // Snapshot the clipboard at gesture start so a later strategy can
            // detect a "copy on select" write that lands before we read.
            gestureStartClipboardChangeCount = NSPasteboard.general.changeCount
        case .leftMouseDragged: input = .mouseDragged(event)
        case .leftMouseUp:      input = .mouseUp(event); lastMouseUpLocation = screenLocation(event)
        case .scrollWheel:      input = .scroll(event)
        case .keyDown:          input = .keyDown(event)
        default:                return
        }

        // Any of these, happening in another app, should close an open popup.
        switch input {
        case .mouseDown, .scroll, .keyDown: onDismiss?(input)
        default: break
        }

        // Broadcast to recognizers; if any completes, fire (debounced) so the
        // app has finished applying the selection before we read it.
        var fired = false
        for gesture in gestures where gesture.consume(input) { fired = true }
        if fired {
            // Trailing-edge debounce: cancel any pending trigger and reschedule, so a
            // rapid multi-click fires the resolve ONCE after the final click (see
            // `pendingTrigger`). Coalescing also lets the selection settle (the OS
            // grows a double→triple-click selection) before we read it.
            pendingTrigger?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingTrigger = nil
                self?.onTrigger?()
            }
            pendingTrigger = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    /// Global-monitor events have no `window`, so `locationInWindow` is already in
    /// screen coordinates (Cocoa, bottom-left origin).
    private func screenLocation(_ event: NSEvent) -> CGPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }
}
