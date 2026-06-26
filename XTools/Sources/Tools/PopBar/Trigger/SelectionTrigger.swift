import AppKit

/// A normalized input event the gesture recognizers understand. Decouples the
/// recognizers from raw `NSEvent` plumbing.
enum InputEvent {
    case mouseDown(NSEvent)
    case mouseDragged(NSEvent)
    case mouseUp(NSEvent)
    case scroll(NSEvent)
    case keyDown(NSEvent)
}

/// Recognizes when "the user just selected text" from a stream of input events.
///
/// Same pluggable shape as `SelectionStrategy`: add a new way to trigger the
/// popup (triple-click, a hotkey, a modifier-drag) by writing one recognizer and
/// registering it with `GlobalInputMonitor` — the rest of the pipeline is blind
/// to how the trigger fired.
protocol SelectionGesture: AnyObject {
    var id: String { get }
    /// Return true when *this* event completes the gesture.
    func consume(_ event: InputEvent) -> Bool
}
