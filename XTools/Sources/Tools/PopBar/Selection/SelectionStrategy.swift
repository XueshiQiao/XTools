import AppKit

/// The selected-text retrieval abstraction.
///
/// This is the layer the whole tool is designed around: getting the user's
/// currently-selected text reliably across every app is the hard part, and no
/// single mechanism works everywhere. So a "strategy" is one *way* to read the
/// selection, and `SelectionResolver` runs an ordered list of them, taking the
/// first that succeeds.
///
/// Adding a new way to read text (AppleScript for browsers, a per-app special
/// case, a future API) means writing one `SelectionStrategy` and registering it
/// in the resolver — nothing else in the pipeline changes. Strategies can also
/// be reordered or combined freely; today we ship two.

/// Identifies which strategy produced a result — for logging, and so a caller
/// can later adapt behavior to *how* the text was obtained.
enum SelectionStrategyID: String {
    case accessibility
    case clipboardCopy
    case appleScript   // reserved for a future browser strategy
    case menuAction    // reserved for a future "press Edit > Copy" strategy
}

/// Where and what we're reading from. Passed into every strategy so none of them
/// reach for global state directly — keeps each strategy testable in isolation.
struct SelectionContext {
    /// The app that owns the selection (frontmost at trigger time).
    let frontmostApp: NSRunningApplication?
    /// Cursor location in screen coordinates (Cocoa, bottom-left origin) — where
    /// the gesture finished. Used to anchor the popup.
    let mouseLocation: CGPoint

    var bundleID: String? { frontmostApp?.bundleIdentifier }
    var pid: pid_t? { frontmostApp?.processIdentifier }
}

/// A successful read. `via` records which strategy won; `bounds` is the optional
/// on-screen rect of the selection (some strategies can provide it for precise
/// popup placement, most can't).
struct SelectionResult {
    let text: String
    let via: SelectionStrategyID
    var bounds: CGRect?
}

/// Why a strategy failed. Only `permissionDenied` is *fatal* — it aborts the
/// whole resolver chain (no fallback can help if Accessibility is off). Every
/// other case just means "try the next strategy".
enum SelectionError: Error {
    case permissionDenied
    case noFocusedElement
    case noSelection
    case unsupported
    case timeout
    case system(Error)

    var isFatal: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// One way to read the current selection.
///
/// Implement this + register in `SelectionResolver` to add a strategy. Return a
/// `SelectionResult` on success, `nil` to fall through, or throw to fall through
/// (a thrown `.permissionDenied` aborts the chain). An empty `text` is treated
/// as failure by the resolver and falls through too.
protocol SelectionStrategy: AnyObject {
    var id: SelectionStrategyID { get }

    /// Cheap pre-filter: return false to skip this strategy for this context
    /// (e.g. a browser-only AppleScript strategy when the frontmost app isn't a
    /// supported browser). Default: always applicable.
    func canHandle(_ context: SelectionContext) -> Bool

    /// Read the selected text. See protocol doc for the success/fallthrough rules.
    func selectedText(_ context: SelectionContext) async throws -> SelectionResult?
}

extension SelectionStrategy {
    func canHandle(_ context: SelectionContext) -> Bool { true }
}
