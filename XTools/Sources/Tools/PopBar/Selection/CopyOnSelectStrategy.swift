import AppKit
import ApplicationServices

/// Fast path for apps with **"copy on select"** — notably terminals like OTTY
/// that render their grid with Metal and expose neither the AX selected-text
/// attribute nor an honored synthetic ⌘C. With copy-on-select on, the app itself
/// writes the selection to the clipboard the instant the user finishes selecting,
/// so we can read it directly instead of synthesizing a ⌘C the app will ignore.
///
/// Why this can't pop on an *unrelated* copy (the safety the design hinges on):
///  1. it only runs after a real selection GESTURE fired (drag-select / double-
///     click) — a background or keyboard ⌘C never triggers PopBar at all;
///  2. the pasteboard `changeCount` must have advanced **during this one gesture**
///     (baseline sampled at mouse-down), so the write is bounded to this drag and
///     can never be stale clipboard content from minutes ago;
///  3. it reuses the issue #15 AX gate (`shouldAttemptCopy`): the focus must
///     plausibly be a text selection, so a non-text drag (a Finder icon, a window)
///     that merely coincides with a background clipboard write is rejected;
///  4. the clipboard string must be non-empty.
/// All four must hold; otherwise it returns nil and the resolver falls through to
/// the synthetic-⌘C `ClipboardCopyStrategy`. It runs after `AccessibilityStrategy`
/// (AX is precise and side-effect-free, so it wins when available) and before the
/// ⌘C fallback (this path is faster and avoids the unhandled-⌘C "funk" beep).
///
/// AX-opaque tradeoff (guard 3, intentional): a terminal that exposes *no* text
/// signal at all (non-text role, no range, no marker range) is rejected even when
/// the clipboard changed during the gesture. We keep the gate because dropping it
/// would let a non-text drag (a Finder icon, a window) that merely coincides with
/// a background clipboard write pop the wheel. The terminals this targets — OTTY —
/// report a text-bearing `AXTextArea` role, so they pass (verified in logs); a
/// genuinely-opaque terminal would warrant a per-app allow path, not relaxing the
/// gate for everyone.
///
/// Unlike the ⌘C strategy this does **not** back up / restore the clipboard: the
/// selected text is there because the *user's* app put it there on purpose
/// (copy-on-select), so leaving it is the correct, expected behavior — we only read.
final class CopyOnSelectStrategy: SelectionStrategy {

    let id = SelectionStrategyID.copyOnSelect
    private static let log = FileLog("PopBar.CopyOnSelect")

    func selectedText(_ context: SelectionContext) async throws -> SelectionResult? {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionDenied }

        // (2) The clipboard must have changed during THIS gesture. No change →
        // the app didn't copy-on-select; let the ⌘C fallback try.
        let current = await MainActor.run { NSPasteboard.general.changeCount }
        guard current != context.clipboardChangeCountAtGestureStart else { return nil }

        // (3) Focus must plausibly hold a text selection (same gate the ⌘C path
        // uses). Rejects a non-text drag that happened to race a background copy.
        let decision = await MainActor.run { AXSelectionProbe.shouldAttemptCopy() }
        guard decision.shouldCopy else {
            Self.log.debug("clipboard changed during gesture but focus not text-like (role=\(decision.role)) — skip")
            return nil
        }

        // (4) Non-empty string on the clipboard.
        let clipboard = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        guard let text = clipboard, !text.isEmpty else { return nil }

        Self.log.info("copy-on-select hit — read \(text.count) char(s) from clipboard (role=\(decision.role))")
        return SelectionResult(text: text, via: id, bounds: nil)
    }
}
