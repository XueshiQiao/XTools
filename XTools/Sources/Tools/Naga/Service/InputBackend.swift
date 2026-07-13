import Foundation

/// Abstraction over "how we observe/intercept side-button presses" so the seize
/// backend (root fix) can later be swapped for a CGEventTap fallback without
/// touching the store / UI.
protocol InputBackend: AnyObject {
    /// Fired once per side-button press, after the keystroke settles: the held
    /// modifier usages (HID 0xE0–0xE7) plus the main key usage (keyboard page).
    /// Key and modifiers can arrive in either order in the HID report, so the
    /// backend debounces briefly and reports the whole combo together.
    var onCapture: ((_ modifiers: [UInt32], _ keyUsage: UInt32) -> Void)? { get set }
    func start()
    func stop()
}
