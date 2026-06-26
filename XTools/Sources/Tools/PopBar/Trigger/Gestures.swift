import AppKit

/// Drag-to-select: a left-mouse-down, several drag events, then mouse-up. We
/// require a minimum number of drag events so an ordinary click (down → up with
/// no drags) doesn't fire.
final class DragSelectGesture: SelectionGesture {
    let id = "drag-select"
    private let dragThreshold: Int
    private var dragCount = 0

    init(dragThreshold: Int = 3) { self.dragThreshold = dragThreshold }

    func consume(_ event: InputEvent) -> Bool {
        switch event {
        case .mouseDown:
            dragCount = 0
        case .mouseDragged:
            dragCount += 1
        case .mouseUp:
            let fired = dragCount >= dragThreshold
            dragCount = 0
            return fired
        default:
            dragCount = 0
        }
        return false
    }
}

/// Double- (or triple-) click to select a word/line. `NSEvent` tracks the click
/// count for us.
final class DoubleClickGesture: SelectionGesture {
    let id = "double-click"

    func consume(_ event: InputEvent) -> Bool {
        if case let .mouseDown(nsEvent) = event {
            return nsEvent.clickCount >= 2
        }
        return false
    }
}
