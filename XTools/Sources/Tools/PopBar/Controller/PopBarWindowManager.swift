import AppKit

/// Owns every PopBar window and is the single source of truth for which windows
/// exist (issue #13). There is exactly ONE transient (unpinned, recycled-per-
/// selection) window plus a set of PINNED windows that each live until their own
/// close button.
///
/// Ownership model:
///  - `transient` — the active popup for the latest selection. Recycled in place
///    on each new selection. Auto-dismiss (outside click) targets ONLY this one.
///  - `pinned` — windows the user pinned. Pinning "graduates" the current
///    transient into this set (it stays on screen with its content/stream intact)
///    and a FRESH transient is created for the next selection.
///
/// All per-window state (selection text, streaming/cancellation generations,
/// in-flight action `Task`) lives on each `PopBarSession` (its placement lives on
/// the session's `PopBarPanel`), so a new selection recycling the transient can
/// never cancel a pinned window's stream.
///
/// Main-thread only by convention (all callers invoke on main).
final class PopBarWindowManager {

    private static let log = FileLog("PopBar.Windows")

    private let llm: LLMService

    /// The active, unpinned popup. Always present; recreated after a pin graduates
    /// the previous one.
    private var transient: PopBarSession
    /// Pinned windows, each self-contained. Kept strongly here; releasing a session
    /// (removing it from this array, after `teardown` + `panel.hide`) deallocates
    /// its `NSPanel`.
    private var pinned: [PopBarSession] = []

    /// How far to nudge a new transient when a pinned window already sits at ~the
    /// same anchor, so stacked windows don't perfectly overlap (issue #13).
    private let stackOffset: CGFloat = 26
    private let overlapRadius: CGFloat = 24

    init(llm: LLMService) {
        self.llm = llm
        transient = PopBarSession(llm: llm)
        wireTransient()
    }

    // MARK: - Queries (used by the controller's trigger/dismiss logic)

    /// The transient popup is currently up and showing its action buttons (safe to
    /// refresh the captured selection under it in place).
    var transientIsShowingActions: Bool {
        transient.isVisible && transient.isShowingActions
    }

    /// The transient popup is visible and not pinned — the only window an outside
    /// click should auto-dismiss (pinned windows persist until their own close).
    var transientIsVisibleUnpinned: Bool {
        transient.isVisible && !transient.isPinned
    }

    // MARK: - Selection → show (transient)

    /// Refresh the transient window's captured selection in place (double→triple-
    /// click growing the same selection). No hide/reposition → no flicker, so the
    /// window's anchor is left untouched (it stays where it was placed).
    func refreshTransientSelection(text: String) {
        guard transient.isShowingActions else { return }
        transient.refreshSelection(text: text)
    }

    /// Show (or recycle) the transient window for a new selection. Works regardless
    /// of how many pinned windows exist.
    func showTransient(text: String, anchor: CGPoint, actions: [PopBarActionConfig]) {
        let placed = offsetAwayFromPinned(anchor)
        transient.show(text: text, anchor: placed, actions: actions)
    }

    /// Dismiss the transient window (outside click / auto-dismiss). Pinned windows
    /// are untouched.
    func dismissTransient() {
        transient.hide()
    }

    // MARK: - Broadcast (settings live updates)

    func setAutoExpandHeight(_ on: Bool) {
        transient.setAutoExpandHeight(on)
        for session in pinned { session.setAutoExpandHeight(on) }
    }

    func setResultFontSize(_ size: Double) {
        transient.setResultFontSize(size)
        for session in pinned { session.setResultFontSize(size) }
    }

    // MARK: - Lifecycle

    /// Hide & release everything (controller stop / tool shutdown).
    func closeAll() {
        transient.hide()
        for session in pinned {
            session.teardown()
            session.panel.hide()
        }
        pinned.removeAll()
    }

    // MARK: - Pin promotion & close

    /// Wire the transient session's panel callbacks. The transient's pin button
    /// GRADUATES it into the pinned set and spins up a fresh transient.
    private func wireTransient() {
        let session = transient
        session.panel.model.onAction = { [weak session] action in session?.runAction(action) }
        session.panel.model.onCopyResult = { [weak self, weak session] text in
            session?.copyResult(text)
            self?.dismissTransient()
        }
        session.panel.model.onClose = { [weak self] in self?.dismissTransient() }
        session.panel.model.onTogglePin = { [weak self] in self?.pinTransient() }
        // A `.dismiss` outcome (e.g. the Copy action) closes the transient.
        session.onDismissOutcome = { [weak self] in self?.dismissTransient() }
    }

    /// Promote the current transient into the pinned set and create a fresh
    /// transient for the next selection. The graduated window keeps its content and
    /// any in-flight stream untouched.
    private func pinTransient() {
        let graduated = transient
        graduated.panel.setPinned(true)
        rewireAsPinned(graduated)
        pinned.append(graduated)
        let count = pinned.count
        Self.log.info("pinned a window — now \(count) pinned")

        // Fresh transient for the next selection.
        transient = PopBarSession(llm: llm)
        wireTransient()
    }

    /// Re-point a graduated session's panel callbacks at itself, so its close / pin
    /// / copy act on THIS window only and never on the (new) transient.
    private func rewireAsPinned(_ session: PopBarSession) {
        session.panel.model.onAction = { [weak session] action in session?.runAction(action) }
        // Copying from a PINNED window keeps it open — the user pinned it precisely
        // to keep the result around. (The transient window, by contrast, dismisses
        // on copy.) It closes only via its own close / unpin button.
        session.panel.model.onCopyResult = { [weak session] text in
            session?.copyResult(text)
        }
        session.panel.model.onClose = { [weak self, weak session] in
            guard let session else { return }
            self?.closePinned(session)
        }
        // Un-pinning a graduated window closes it (it has no transient semantics, so
        // nothing else would ever dismiss it — leaving an orphan undismissable
        // window). Closing is the single, predictable outcome.
        session.panel.model.onTogglePin = { [weak self, weak session] in
            guard let session else { return }
            self?.closePinned(session)
        }
        session.onDismissOutcome = { [weak self, weak session] in
            guard let session else { return }
            self?.closePinned(session)
        }
    }

    /// Close one pinned window: cancel its stream, hide it, and drop our strong
    /// reference so its `NSPanel` deallocates. Other pinned windows are untouched.
    private func closePinned(_ session: PopBarSession) {
        guard let index = pinned.firstIndex(where: { $0 === session }) else { return }
        session.teardown()
        session.panel.hide()
        pinned.remove(at: index)
        let count = pinned.count
        Self.log.info("closed a pinned window — now \(count) pinned")
    }

    // MARK: - Stacking

    /// If a pinned window already sits at ~the same spot the new transient would
    /// land, nudge the transient diagonally so the two don't perfectly overlap.
    ///
    /// `PopBarPanel.show(at:)` places a fresh popup with its bottom-center just
    /// above the selection anchor (`clampedOrigin`: bottom-center ≈ `(anchor.x,
    /// anchor.y + 12)`). So we compare the prospective transient's bottom-center to
    /// each pinned window's ACTUAL current bottom-center (the SAME geometric
    /// reference, and one that tracks user drags — issue #11/#13) rather than
    /// mixing a raw anchor with a window center. We offset the bottom-center, then
    /// convert back to the equivalent anchor for `show(at:)`.
    private func offsetAwayFromPinned(_ anchor: CGPoint) -> CGPoint {
        let anchorLift: CGFloat = 12   // matches clampedOrigin's `anchor.y + 12`
        let pinnedBottoms = pinned.map { $0.currentBottomCenter }
        var bottom = CGPoint(x: anchor.x, y: anchor.y + anchorLift)
        var guardCount = 0
        while pinnedBottoms.contains(where: { hypot($0.x - bottom.x, $0.y - bottom.y) < overlapRadius }),
              guardCount < pinnedBottoms.count + 1 {
            bottom.x += stackOffset
            bottom.y -= stackOffset
            guardCount += 1
        }
        return CGPoint(x: bottom.x, y: bottom.y - anchorLift)
    }
}
