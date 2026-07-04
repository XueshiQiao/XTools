import AppKit
import SwiftUI

/// An `NSHostingView` that:
///  - accepts the first click even when our app isn't the active one — so a single
///    tap on a capsule button works without first having to activate XTools (the
///    panel is non-activating by design);
///  - lets a mouse-down on an *empty* region of the capsule drag the whole window.
///
/// `NSHostingView` normally returns `false` from `mouseDownCanMoveWindow`, which is
/// why a borderless panel + `isMovableByWindowBackground` still can't be dragged
/// through SwiftUI. Returning `true` here lets AppKit move the window when the
/// click lands on background — and SwiftUI's own controls (buttons) intercept the
/// click first, so they keep working. (Verified by dragging the live capsule.)
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Wheel mode only: restrict AppKit hit-testing to the visible ring `[inner,
    /// outer]` from the view's center. SwiftUI's `.contentShape` governs only its own
    /// gesture resolution; the panel is still a square window, so without this a click
    /// in the hollow centre or a transparent corner is eaten by XTools instead of
    /// passing THROUGH to the app behind (and reaching the global dismiss monitor).
    /// nil = capsule mode → the whole opaque view hit-tests as before.
    var ringHitTest: (inner: CGFloat, outer: CGFloat)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let ring = ringHitTest {
            let p = convert(point, from: superview)   // → this view's coordinate space
            let dist = hypot(p.x - bounds.midX, p.y - bounds.midY)
            if dist < ring.inner || dist > ring.outer { return nil }   // transparent → click-through
        }
        return super.hitTest(point)
    }
}

/// The floating capsule window.
///
/// The recipe (`.nonactivatingPanel` + `.floating` level + `canJoinAllSpaces` +
/// `orderFront` rather than `makeKeyAndOrderFront`) is the bit every PopClip-
/// style tool converges on: it floats above everything, follows you across
/// Spaces, and — critically — does NOT steal focus from the app that owns the
/// selection. If it stole focus, the source selection would collapse and the
/// action would read empty text.
/// Main-thread only by convention (callers always invoke it on main).
final class PopBarPanel {

    let model = PopBarPanelModel()

    private let panel: NSPanel
    /// Kept so `show` can switch its AppKit hit-test region per style (wheel → ring
    /// only; capsule → whole view).
    private let hosting: FirstMouseHostingView<PopBarContentView>
    /// The cursor point the popup is anchored to, so re-fitting after a phase
    /// change keeps it in place.
    private var anchor: CGPoint = .zero
    /// Set once the user has dragged the capsule (issue #11). After that, a phase
    /// change must re-fit *in place* (around the current frame's top-center) rather
    /// than snap back to `anchor` — otherwise tapping an action yanks the popup the
    /// user just moved back to the original selection point.
    private var userMoved = false
    /// True while we reposition the window ourselves, so our own `setFrameOrigin`
    /// doesn't get mistaken for a user drag in the move observer.
    private var repositioning = false
    private var moveObserver: NSObjectProtocol?
    /// Last window height we fit to. Used to coalesce auto-expand re-fits: a
    /// content-height change only re-fits if the measured window size actually
    /// changed, so steady text costs nothing.
    private var lastFitHeight: CGFloat = 0
    /// The locked TOP edge of the current result presentation (issue #12). While in
    /// the `.result` phase (and the window hasn't been user-dragged), the window's
    /// top stays put and it grows only DOWNWARD as content streams / auto-height
    /// grows — no upward expansion / "up then down" jump. Captured on the FIRST
    /// result fit from the capsule's current top, reused on every later re-fit, and
    /// reset to `nil` whenever the popup re-shows or returns to `.actions`.
    private var resultTopY: CGFloat?

    /// Auto-expand (issue #12) bounds for the result scroll area. The content
    /// grows within `[min, max]`; beyond `max` it scrolls. `max` is further capped
    /// at run time to ~60% of the popup's own screen so a tall result can't exceed
    /// a small display.
    private let resultMinHeight: CGFloat = 120
    private let resultMaxHeight: CGFloat = 560
    private let resultScreenFraction: CGFloat = 0.6
    /// Latest natural content height SwiftUI reported, cached regardless of the
    /// auto-expand flag so toggling the setting ON for an already-open result can
    /// clamp + apply it immediately (the content size may not change, so the
    /// measurement callback would not fire again on its own).
    private var lastMeasuredContentHeight: CGFloat = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                // native window shadow — crisp, GPU-clipped
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Draggable by its background whether pinned or not (issue #11). The
        // hosting view returns `mouseDownCanMoveWindow = true` so the drag reaches
        // AppKit through SwiftUI; controls still intercept their own clicks.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        hosting = FirstMouseHostingView(rootView: PopBarContentView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // A background drag moves the window; remember it so later re-fits keep the
        // popup where the user put it. Ignore our own programmatic repositions.
        //
        // `queue: nil` is deliberate: it delivers synchronously on the posting
        // thread. Our own `setFrameOrigin` (always on main) therefore runs this
        // block *inside* the call while `repositioning == true`, so a programmatic
        // move can never be mistaken for a user drag. A `.main`-queue observer would
        // instead defer the callback until after `repositioning` is reset to false.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            guard let self, !self.repositioning else { return }
            self.userMoved = true
        }

        // SwiftUI reports the result content's natural height here; we clamp it
        // against the popup's screen and re-fit. This single path drives every
        // auto-expand resize (streaming deltas, one-shot results, error results).
        model.onMeasuredContentHeight = { [weak self] measured in
            self?.applyMeasuredContentHeight(measured)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    var isVisible: Bool { panel.isVisible }

    /// The window's current on-screen bottom-center. Reflects user drags (issue
    /// #11). Used for stacking/overlap decisions because a fresh popup is placed
    /// with its bottom-center just above the selection anchor (`clampedOrigin`), so
    /// comparing bottom-centers compares the SAME geometric reference across
    /// windows regardless of their differing heights.
    var frameBottomCenter: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.minY) }

    /// Whether the capsule is pinned open (ignores auto-dismiss).
    var isPinned: Bool { model.isPinned }

    /// Whether the capsule is currently showing its action buttons (not a loading
    /// spinner or a result), i.e. safe to refresh the captured selection under it.
    var isShowingActions: Bool {
        if case .actions = model.phase { return true }
        return false
    }

    /// Pin / unpin: pinned capsules survive outside clicks. Dragging works in
    /// both states (`isMovableByWindowBackground` is left on — see `init`).
    func setPinned(_ on: Bool) {
        model.isPinned = on
    }

    /// Show the capsule (in its `.actions` phase) anchored above `screenPoint`.
    func show(at screenPoint: CGPoint) {
        anchor = screenPoint
        userMoved = false   // a fresh popup re-anchors to the cursor
        // Pick up the current presentation style for this show (capsule vs wheel).
        // Read here so toggling it in settings affects the next popup/preview.
        model.style = PopBarPreferences.style
        model.wheelLayout = PopBarPreferences.wheelLayout   // user-adjustable radii + icon/label toggles
        model.autoHideOnExitRing = PopBarPreferences.wheelAutoHideOnExit   // wheel: hide when pointer leaves the ring
        // Pick up the current auto-expand preference for this show (the user may
        // have toggled it in settings since the last popup).
        model.autoExpandHeight = PopBarPreferences.autoExpandHeight
        // Same for the result font size (issue #14).
        model.resultFontSize = PopBarPreferences.resultFontSize
        model.resultContentHeight = nil   // re-measure for this popup's content
        lastMeasuredContentHeight = 0     // drop the previous popup's measurement
        model.phase = .actions
        model.streamingText = ""
        resultTopY = nil   // a fresh popup re-anchors; the result top re-locks on its first result fit
        setPinned(false)   // a fresh popup always starts unpinned
        updateWheelHitTest()   // wheel ring hit-test is scoped to the actions phase
        // Let SwiftUI lay out the actions row, then size + place the window.
        DispatchQueue.main.async { [weak self] in
            self?.fitAndPlace()
            self?.panel.orderFront(nil)
        }
    }

    /// Switch the capsule's content (e.g. to loading / result) and re-fit. When
    /// entering `.result`, seed the live `streamingText` with the phase's text so
    /// the result view (which reads `streamingText`) shows the initial value.
    func applyPhase(_ phase: PopBarPanelModel.Phase) {
        if case .result(let text) = phase { model.streamingText = text }
        // Leaving the result phase releases the locked top so the next result
        // (or the actions capsule) re-anchors fresh (issue #12).
        if case .result = phase {} else { resultTopY = nil }
        model.phase = phase
        // The shared loading/result chrome is a normal rectangular panel (wider than
        // the wheel). Clear the wheel's annular hit-test or its toolbar/text outside
        // the old ring would be dead (it only applies to the wheel's actions phase).
        updateWheelHitTest()
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
    }

    /// Scope the wheel's AppKit annular hit-test to the wheel's `.actions` phase
    /// only. Any other phase (or the capsule style) hit-tests the whole rectangular
    /// view, so the result/loading chrome stays fully clickable.
    private func updateWheelHitTest() {
        hosting.ringHitTest = (model.style.isWheel && isShowingActions)
            ? (inner: model.wheelLayout.innerRadius, outer: model.wheelLayout.outerRadius)
            : nil
    }

    /// Push a streaming delta into an already-showing result panel. Caller
    /// guarantees we're in `.result`.
    ///
    /// With auto-expand OFF (issue #7 behavior) the result frame is fixed, so the
    /// window stays put — only the text inside the scroll view changes. With
    /// auto-expand ON, the resulting content-height change is reported back through
    /// `onMeasuredContentHeight`, which clamps + re-fits the window; we don't have
    /// to do anything extra here.
    func updateResultText(_ text: String) {
        model.updateStreamingText(text)
    }

    /// Apply a live change to the auto-expand preference (from settings) onto an
    /// already-open panel, then re-fit so the change takes effect immediately.
    func setAutoExpandHeight(_ on: Bool) {
        model.autoExpandHeight = on
        // Turning ON: clamp the last-measured content and apply it so an already-open
        // result grows immediately, even though its content size hasn't changed (the
        // measurement callback wouldn't fire again on its own). Turning OFF: the view
        // reverts to the fixed height.
        if on { model.resultContentHeight = clampedResultHeight(forContent: lastMeasuredContentHeight) }
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
    }

    /// Apply a live result-font-size change (from settings) onto an already-open
    /// panel (issue #14). Changing the size re-renders the Markdown; with auto-expand
    /// ON the content-height measure callback fires and re-fits, so we don't re-fit
    /// here. The result top stays locked (issue #12), so it grows/shrinks downward.
    func setResultFontSize(_ size: Double) {
        model.resultFontSize = size
    }

    /// Apply a live wheel-geometry change (from the settings sliders) onto the showing
    /// wheel preview so dragging the inner/outer radius — or toggling icons/labels —
    /// updates it in place. Mirrors `setAutoExpandHeight`/`setResultFontSize`. Re-scopes
    /// the ring hit-test to the new radii and re-fits the window, but only while the
    /// wheel is actually showing its ring (no effect on a result/capsule/hidden panel).
    func setWheelLayout(_ layout: WheelLayout) {
        model.wheelLayout = layout
        guard panel.isVisible, model.style.isWheel, isShowingActions else { return }
        updateWheelHitTest()
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
    }

    /// SwiftUI measured the result content's natural height. Cache it (always),
    /// then — when auto-expand is ON — clamp it against the popup's own screen +
    /// the min/max, store it for the view to apply, and re-fit the window (coalesced
    /// so an unchanged height costs nothing). When OFF we only cache, so a later
    /// settings toggle can apply it without waiting for the next layout change.
    private func applyMeasuredContentHeight(_ measured: CGFloat) {
        lastMeasuredContentHeight = measured
        guard model.autoExpandHeight else { return }
        let clamped = clampedResultHeight(forContent: measured)
        if let current = model.resultContentHeight, abs(current - clamped) < 0.5 { return }
        model.resultContentHeight = clamped
        // Let SwiftUI apply the new frame height, then size the window to it.
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace(coalesce: true) }
    }

    /// Clamp a measured content height to `[min, cap]`, where `cap` is the smaller
    /// of `resultMaxHeight` and a fraction of the popup screen's visible height so a
    /// tall result never exceeds the display it's shown on (issue #12).
    private func clampedResultHeight(forContent measured: CGFloat) -> CGFloat {
        // Use the screen the popup is actually on: its current frame center once the
        // user has dragged it (issue #11), otherwise the anchor point.
        let probe = userMoved ? CGPoint(x: panel.frame.midX, y: panel.frame.midY) : anchor
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main
        let screenCap = (screen?.visibleFrame.height).map { $0 * resultScreenFraction } ?? resultMaxHeight
        let cap = min(resultMaxHeight, screenCap)
        let lower = min(resultMinHeight, cap)   // never above the cap on a tiny screen
        // Round the content height UP to a whole point before clamping. The measurement
        // already covers the FULL scroll content (Markdown + bottom anchor); the ceil
        // just absorbs sub-point layout rounding so the scroll frame is never a fraction
        // shorter than its content — which is what would leave a 1px scrollbar behind.
        return min(max(measured.rounded(.up), lower), cap)
    }

    func hide() {
        panel.orderOut(nil)
        model.phase = .actions
        model.streamingText = ""
        resultTopY = nil   // released so the next presentation re-anchors (issue #12)
        setPinned(false)
    }

    // MARK: - Sizing / placement

    /// Size the window to its content and place it.
    ///
    /// `coalesce` (used by streaming re-fits) skips all work when the fitted height
    /// is unchanged from the last fit, so a delta that doesn't grow the window
    /// costs nothing beyond measuring.
    private func fitAndPlace(coalesce: Bool = false) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize

        if coalesce && abs(size.height - lastFitHeight) < 0.5 { return }
        lastFitHeight = size.height

        // Where to keep the popup as it resizes (issue #12):
        //  - dragged: keep it pinned where the user put it (hold the dragged top).
        //  - `.actions` (not dragged): capsule above the cursor (unchanged).
        //  - `.result` (not dragged): hold the TOP edge and grow only DOWNWARD —
        //    lock the top on the first result fit (from the capsule's current top so
        //    actions→result doesn't jump), then reuse it on every later re-fit.
        let oldFrame = panel.frame
        // Capture the locked top BEFORE resizing, on the first result fit.
        if !userMoved, case .result = model.phase, resultTopY == nil {
            resultTopY = oldFrame.maxY
        }
        repositioning = true
        panel.setContentSize(size)
        let newSize = panel.frame.size
        let origin: CGPoint
        if userMoved {
            origin = preservedOrigin(oldFrame: oldFrame, newSize: newSize)
        } else if case .result = model.phase {
            origin = resultOrigin(for: newSize)
        } else if case .actions = model.phase, model.style.isWheel {
            // Both wheel styles are centered ON the cursor (the hollow center reveals
            // the selection through it), unlike the capsule which sits above it.
            origin = wheelOrigin(for: newSize)
        } else {
            origin = clampedOrigin(for: newSize)
        }
        panel.setFrameOrigin(origin)
        repositioning = false

        panel.invalidateShadow()   // recompute the native shadow for the new rounded size
    }

    /// Keep the popup at the position the user dragged it to while it resizes: hold
    /// the top edge and horizontal center steady (matching the original "above &
    /// centered" feel), then clamp inside the visible frame.
    private func preservedOrigin(oldFrame: NSRect, newSize: CGSize) -> CGPoint {
        let centerX = oldFrame.midX
        let topY = oldFrame.maxY
        var origin = CGPoint(x: centerX - newSize.width / 2, y: topY - newSize.height)

        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: oldFrame.midX, y: oldFrame.midY)) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - newSize.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - newSize.height - margin)
        }
        return origin
    }

    /// Center the wheel ON the cursor (both axes), then clamp inside the visible
    /// frame so it never runs off a screen edge.
    private func wheelOrigin(for size: CGSize) -> CGPoint {
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        return origin
    }

    /// Center horizontally on the cursor, sit just above it, then clamp fully
    /// inside the screen's visible frame (Xpop ships without this and runs off
    /// the edge near screen borders).
    private func clampedOrigin(for size: CGSize) -> CGPoint {
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y + 12)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        return origin
    }

    /// Place a result presentation with a FIXED top edge so it grows only DOWNWARD
    /// (issue #12). The top (`resultTopY`, locked on the first result fit) stays put
    /// while the height changes; only the bottom extends down. X stays centered on
    /// the cursor (same as `clampedOrigin`). Clamped inside the visible frame so a
    /// result that would grow past the bottom is held at the bottom (a safety clamp —
    /// the auto-height cap already bounds growth).
    private func resultOrigin(for size: CGSize) -> CGPoint {
        let top = resultTopY ?? (anchor.y + 12)
        var origin = CGPoint(x: anchor.x - size.width / 2, y: top - size.height)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        return origin
    }
}
