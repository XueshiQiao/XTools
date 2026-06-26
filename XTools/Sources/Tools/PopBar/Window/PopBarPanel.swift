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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
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

        let hosting = FirstMouseHostingView(rootView: PopBarContentView(model: model))
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
        // Pick up the current auto-expand preference for this show (the user may
        // have toggled it in settings since the last popup).
        model.autoExpandHeight = PopBarPreferences.autoExpandHeight
        model.resultContentHeight = nil   // re-measure for this popup's content
        lastMeasuredContentHeight = 0     // drop the previous popup's measurement
        model.phase = .actions
        model.streamingText = ""
        setPinned(false)   // a fresh popup always starts unpinned
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
        model.phase = phase
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
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
        return min(max(measured, lower), cap)
    }

    func hide() {
        panel.orderOut(nil)
        model.phase = .actions
        model.streamingText = ""
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

        // Where to keep the popup as it resizes: by default re-anchor to the cursor;
        // once the user has dragged it, keep it pinned to where they put it (resize
        // around the current top-center so it grows/shrinks in place).
        let oldFrame = panel.frame
        repositioning = true
        panel.setContentSize(size)
        let origin = userMoved
            ? preservedOrigin(oldFrame: oldFrame, newSize: panel.frame.size)
            : clampedOrigin(for: panel.frame.size)
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
}
