import AppKit
import SwiftUI

/// An `NSHostingView` that accepts the first click even when our app isn't the
/// active one — so a single tap on a capsule button works without first having
/// to activate XTools (the panel is non-activating by design).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        panel.hasShadow = false               // SwiftUI draws its own soft shadow
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = FirstMouseHostingView(rootView: PopBarContentView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    /// Show the capsule (in its `.actions` phase) anchored above `screenPoint`.
    func show(at screenPoint: CGPoint) {
        anchor = screenPoint
        model.phase = .actions
        // Let SwiftUI lay out the actions row, then size + place the window.
        DispatchQueue.main.async { [weak self] in
            self?.fitAndPlace()
            self?.panel.orderFront(nil)
        }
    }

    /// Switch the capsule's content (e.g. to loading / result) and re-fit.
    func applyPhase(_ phase: PopBarPanelModel.Phase) {
        model.phase = phase
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
    }

    func hide() {
        panel.orderOut(nil)
        model.phase = .actions
    }

    // MARK: - Sizing / placement

    private func fitAndPlace() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(clampedOrigin(for: panel.frame.size))
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
