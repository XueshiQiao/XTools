import AppKit
import QuartzCore

/// The user's chosen region. `globalCocoaRect` is in GLOBAL Cocoa coordinates
/// (bottom-left origin, y up — same space as NSScreen.frame / NSEvent.mouseLocation).
struct RegionSelection {
    let screen: NSScreen
    let globalCocoaRect: CGRect
}

// MARK: - Controller

/// Puts a dimmed drag-to-select overlay on EVERY screen and yields the chosen region.
///
/// One borderless overlay window covers each `NSScreen`, so the whole desktop is
/// darkened at once. The drag happens on whichever screen the pointer is over; that
/// overlay reports its finalized rect (in view coordinates) back here, and the
/// controller converts it to global Cocoa coordinates via the reporting window —
/// which is what keeps the math correct on multi-monitor / negative-origin layouts
/// (e.g. a second display to the LEFT of the main one, whose `frame.origin.x` is
/// negative). Main-thread only.
final class RegionSelectionController {

    private static let log = FileLog("PopBar.OCR")

    /// Live overlays, one per screen. Holding them here is the only strong
    /// reference — `teardown()` empties this to dismiss + release them all.
    private var overlays: [RegionOverlayWindow] = []
    private var completion: ((RegionSelection?) -> Void)?
    /// Guards against a double callback: only the first finish/cancel wins.
    private var hasFinished = false
    /// The app that was frontmost before we activated XTools to capture Esc; focus is
    /// returned to it once the overlay is dismissed (success or cancel).
    private var previousApp: NSRunningApplication?

    /// Shows overlays on all screens. Calls `completion` exactly ONCE, on the main
    /// thread: a RegionSelection, or nil if the user cancelled (Esc / right-click /
    /// a rect smaller than 8x8 points). Tears down every overlay before calling back.
    func begin(completion: @escaping (RegionSelection?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.begin(completion: completion) }
            return
        }
        // A fresh session supersedes any stragglers from a previous call.
        teardown()

        self.completion = completion
        self.hasFinished = false

        let mouse = NSEvent.mouseLocation
        // Remember who was frontmost so we can hand focus back after the overlay closes.
        previousApp = NSWorkspace.shared.frontmostApplication
        // Activate so a borderless overlay can become key and receive Esc via keyDown.
        NSApp.activate(ignoringOtherApps: true)

        let screens = NSScreen.screens
        for screen in screens {
            let window = RegionOverlayWindow(screen: screen)
            let view = RegionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self, weak window] rectInView in
                guard let self, let window else { return }
                self.finish(rectInView: rectInView, window: window, screen: screen)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(window)
        }

        // Make the overlay under the pointer key so keyboard (Esc) is routed to it;
        // fall back to the first overlay. Mouse events reach whichever window is under
        // the cursor regardless of key, so only keyboard focus needs steering here.
        let keyIndex = screens.firstIndex { $0.frame.contains(mouse) } ?? 0
        if overlays.indices.contains(keyIndex) {
            let window = overlays[keyIndex]
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
        }
        Self.log.info("region overlay shown across \(self.overlays.count) screen(s)")
    }

    // MARK: - Outcomes

    private func finish(rectInView: CGRect, window: RegionOverlayWindow, screen: NSScreen) {
        guard !hasFinished else { return }
        hasFinished = true

        // view coords → window base coords → global Cocoa coords. `convertPoint(toScreen:)`
        // reads the window's real on-screen origin, so a negative-origin display is handled
        // without any manual per-screen offset. Size is translation-invariant.
        let winRect = window.contentView?.convert(rectInView, to: nil) ?? rectInView
        let globalOrigin = window.convertPoint(toScreen: winRect.origin)
        let globalRect = CGRect(origin: globalOrigin, size: winRect.size)

        teardown()
        restorePreviousApp()
        let done = completion
        completion = nil
        Self.log.info("region selected \(Int(globalRect.width))x\(Int(globalRect.height)) pt on \(screen.localizedName)")
        done?(RegionSelection(screen: screen, globalCocoaRect: globalRect))
    }

    private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        teardown()
        restorePreviousApp()
        let done = completion
        completion = nil
        Self.log.info("region selection cancelled")
        done?(nil)
    }

    /// Dismisses and releases every overlay window.
    private func teardown() {
        for window in overlays {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlays.removeAll()
    }

    /// Hand keyboard focus back to whatever app was frontmost before we activated
    /// XTools. On success the capsule is a non-activating panel, so restoring the prior
    /// app doesn't hide it; on cancel the user simply stays where they were.
    private func restorePreviousApp() {
        guard let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        app.activate(options: [])
        previousApp = nil
    }
}

// MARK: - Overlay window

/// A borderless, transparent overlay window sized to one screen. Sits at
/// `.screenSaver` level so it covers the menu bar and Dock, and overrides
/// `canBecomeKey` (borderless windows refuse key status by default) so it can
/// receive the Esc keyDown that cancels the session.
private final class RegionOverlayWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay view

/// The self-drawn dim + drag-to-select surface for one screen.
///
/// Layer-backed for silky dragging: the full-screen dim is a single `CAShapeLayer`
/// whose even-odd path "punches a hole" at the selection rect (the selection then
/// shows the real screen at full brightness). Updating that path on every
/// `mouseDragged` is a cheap, GPU-composited property change — no per-frame
/// full-screen pixel fill. The 1px border and the two HUD labels are sibling layers.
///
/// Coordinates are the view's default bottom-left (non-flipped) space, which lines
/// up 1:1 with the sublayers' geometry and with global Cocoa coordinates.
private final class RegionOverlayView: NSView {

    /// Finalized selection rect in this view's coordinates.
    var onSelect: ((CGRect) -> Void)?
    /// User cancelled the whole session from this overlay.
    var onCancel: (() -> Void)?

    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?

    // Layers, back-to-front.
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let dimLabelBG = CALayer()
    private let dimLabel = CATextLayer()
    private let hintBG = CALayer()
    private let hintLabel = CATextLayer()

    private let dimFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        dimLayer.fillRule = .evenOdd

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        borderLayer.isHidden = true

        configureLabel(dimLabel, background: dimLabelBG, cornerRadius: 5,
                       backgroundAlpha: 0.72, font: dimFont)
        dimLabelBG.isHidden = true
        dimLabel.isHidden = true

        configureLabel(hintLabel, background: hintBG, cornerRadius: 0,
                       backgroundAlpha: 0.75, font: hintFont)
        hintLabel.string = L("popbar.ocr.overlay.hint")

        for sub in [dimLayer, borderLayer, dimLabelBG, dimLabel, hintBG, hintLabel] {
            layer?.addSublayer(sub)
        }

        // Size is fixed (= the screen), so lay everything out now rather than relying
        // on an automatic layout pass, which a non-constraint layer-backed view may
        // not get. `layout()` still handles the (unexpected) resize case.
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        layoutHint()
        refreshSelectionLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        layoutHint()
        refreshSelectionLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sub in [dimLayer, borderLayer, dimLabelBG, dimLabel, hintBG, hintLabel] {
            sub.contentsScale = scale
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.cursorUpdate` keeps the crosshair even on the non-key overlays.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Mouse / keyboard

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        selectionRect = nil
        refreshSelectionLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        // Clamp to this screen so the selection can't spill onto another display
        // (capture is per-display).
        let current = clampToBounds(convert(event.locationInWindow, from: nil))
        selectionRect = normalizedRect(from: origin, to: current)
        refreshSelectionLayers()
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard let rect = selectionRect, rect.width >= 8, rect.height >= 8 else {
            onCancel?()   // a bare click or a sub-8x8 drag cancels the session
            return
        }
        onSelect?(rect)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Drawing helpers

    /// Rebuilds the dim hole, border, and dimension label for the current selection.
    /// Wrapped in a non-animating transaction so the hole tracks the cursor with no lag.
    private func refreshSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let outer = CGMutablePath()
        outer.addRect(bounds)
        if let sel = selectionRect, !sel.isEmpty { outer.addRect(sel) }
        dimLayer.path = outer

        guard let sel = selectionRect, !sel.isEmpty else {
            borderLayer.isHidden = true
            dimLabelBG.isHidden = true
            dimLabel.isHidden = true
            return
        }

        borderLayer.path = CGPath(rect: sel.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        borderLayer.isHidden = false
        layoutDimensionLabel(for: sel)
        dimLabelBG.isHidden = false
        dimLabel.isHidden = false
    }

    /// "640 × 220" in points, in a dark pill just below-right of the selection,
    /// clamped to stay fully on-screen.
    private func layoutDimensionLabel(for sel: CGRect) {
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        dimLabel.string = text

        let textSize = measure(text, font: dimFont)
        let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 8, margin: CGFloat = 6
        let boxSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)

        // Prefer below the selection (lower y), right-aligned to its right edge; if
        // there's no room below, tuck it just inside the selection's bottom.
        var x = sel.maxX - boxSize.width
        var y = sel.minY - gap - boxSize.height
        if y < margin { y = sel.minY + gap }
        x = min(max(x, margin), bounds.width - boxSize.width - margin)
        y = min(max(y, margin), bounds.height - boxSize.height - margin)

        let box = CGRect(x: x, y: y, width: boxSize.width, height: boxSize.height)
        dimLabelBG.frame = box
        dimLabel.frame = box.insetBy(dx: padX, dy: padY)
    }

    /// Centers the bottom hint pill on this screen.
    private func layoutHint() {
        let text = hintLabel.string as? String ?? ""
        let textSize = measure(text, font: hintFont)
        let padX: CGFloat = 14, padY: CGFloat = 9
        let boxSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        let origin = CGPoint(x: bounds.midX - boxSize.width / 2, y: 80)
        let box = CGRect(origin: origin, size: boxSize)
        hintBG.frame = box
        hintBG.cornerRadius = box.height / 2   // pill
        hintLabel.frame = box.insetBy(dx: padX, dy: padY)
    }

    // MARK: Utilities

    private func configureLabel(_ label: CATextLayer, background: CALayer,
                                cornerRadius: CGFloat, backgroundAlpha: CGFloat, font: NSFont) {
        background.backgroundColor = NSColor.black.withAlphaComponent(backgroundAlpha).cgColor
        background.cornerRadius = cornerRadius
        label.font = font
        label.fontSize = font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.truncationMode = .end
    }

    private func measure(_ text: String, font: NSFont) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width),
                y: min(max(p.y, 0), bounds.height))
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Toast

/// A minimal, one-shot fading label used for OCR feedback ("no text found", etc.).
enum RegionToast {

    /// Strong references held only for the lifetime of each toast's fade animation,
    /// so a panel isn't deallocated mid-fade.
    private static var live: [NSPanel] = []

    /// Show `text` centered horizontally at the given GLOBAL Cocoa point, fading out
    /// after ~1.2s. Non-interactive; ignores mouse events.
    static func show(_ text: String, atGlobalCocoa point: CGPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(text, atGlobalCocoa: point) }
            return
        }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padX: CGFloat = 16, padY: CGFloat = 10
        let size = CGSize(width: ceil(label.frame.width) + padX * 2,
                          height: ceil(label.frame.height) + padY * 2)
        // Centered on point.x, sitting a little ABOVE point.y (global Cocoa, y up).
        let frame = CGRect(x: point.x - size.width / 2, y: point.y + 12,
                           width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 10
        label.frame = CGRect(x: padX, y: padY, width: size.width - padX * 2, height: size.height - padY * 2)
        container.addSubview(label)
        panel.contentView = container

        live.append(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                live.removeAll { $0 === panel }
            })
        }
    }
}
