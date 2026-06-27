import AppKit

/// The fallback: when the Accessibility API can't read the selection (browsers
/// that hide their tree, Electron before it's enabled, custom text views), copy
/// it the way a human would — synthesize ⌘C and read the clipboard — but do it
/// non-destructively by backing up and restoring the clipboard around the copy.
///
/// Correctness hinges on two things, both lifted from the mature reference
/// implementations:
///  - **changeCount polling**: don't read after a fixed sleep (the target app
///    copies asynchronously); poll `NSPasteboard.changeCount` until it actually
///    advances, then read. Avoids grabbing stale/old clipboard text.
///  - **full backup/restore**: snapshot every item and type, restore after, so
///    the user's clipboard is untouched.
final class ClipboardCopyStrategy: SelectionStrategy {

    let id = SelectionStrategyID.clipboardCopy
    private static let log = FileLog("PopBar.Clipboard")

    /// Poll cadence and ceiling for confirming the copy landed.
    private let pollInterval: TimeInterval = 0.005   // 5ms
    private let pollTimeout: TimeInterval = 0.4       // 400ms

    func selectedText(_ context: SelectionContext) async throws -> SelectionResult? {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionDenied }

        // issue #15 — gate the synthetic ⌘C on a plausible TEXT selection. The
        // drag gesture fires on ANY drag (a Finder icon, a list row, a window),
        // and posting ⌘C with nothing copyable makes the frontmost app play the
        // system "funk" beep. Ask AX first; if there's clearly no text selection,
        // skip the copy silently (no beep). See AXSelectionProbe for the policy
        // and the AX-opaque (Electron) tradeoff.
        let decision = await MainActor.run { AXSelectionProbe.shouldAttemptCopy() }
        guard decision.shouldCopy else {
            Self.log.debug("skip ⌘C — no text selection (role=\(decision.role) selRangeLen=\(decision.rangeLength))")
            return nil
        }
        Self.log.debug("send ⌘C — role=\(decision.role) selRangeLen=\(decision.rangeLength)")

        let backup = await MainActor.run { Pasteboard.backup() }
        let initialChangeCount = await MainActor.run { NSPasteboard.general.changeCount }

        await MainActor.run { KeySender.copy() }

        var captured: String?
        let start = Date()
        while Date().timeIntervalSince(start) < pollTimeout {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            let (changeCount, string) = await MainActor.run {
                (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
            }
            if changeCount != initialChangeCount {
                // Clipboard advanced. Accept a non-empty string; a changed-but-empty
                // clipboard means another manager raced us — keep waiting briefly.
                if let string, !string.isEmpty { captured = string; break }
            }
        }

        // Always restore, whether or not we captured anything.
        await MainActor.run { Pasteboard.restore(backup) }

        guard let text = captured else {
            Self.log.debug("clipboard copy did not land within \(Int(self.pollTimeout * 1000))ms")
            return nil
        }
        return SelectionResult(text: text, via: id, bounds: nil)
    }
}
