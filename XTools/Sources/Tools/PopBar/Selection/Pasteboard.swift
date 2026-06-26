import AppKit

/// Non-destructive pasteboard helpers used by the clipboard-copy fallback.
///
/// Backing up before a synthesized copy and restoring after is what keeps the
/// fallback from clobbering whatever the user already had on their clipboard. We
/// deep-copy *every* item and *every* type (not just the string), matching how
/// the mature reference implementations do it.
///
/// Call these on the main thread (the strategy wraps them in `MainActor.run`).
enum Pasteboard {

    /// Snapshot all current pasteboard items (all representations).
    static func backup() -> [NSPasteboardItem] {
        let pasteboard = NSPasteboard.general
        var copied: [NSPasteboardItem] = []
        guard let items = pasteboard.pasteboardItems else { return copied }
        for item in items {
            let dup = NSPasteboardItem()
            // Snapshot the type list first — mutating while iterating `item.types`
            // can crash (a documented edge in the reference code).
            let types = item.types
            for type in types {
                if let data = item.data(forType: type) {
                    dup.setData(data, forType: type)
                }
            }
            copied.append(dup)
        }
        return copied
    }

    /// Restore a previously-captured snapshot. Always clears first so the text we
    /// injected via the synthesized copy is removed — when the snapshot was empty
    /// (the user's clipboard started empty) this correctly leaves it empty again,
    /// rather than leaving our copied selection behind.
    ///
    /// Only call this after a `backup()` + a copy we performed; it unconditionally
    /// overwrites the clipboard.
    @discardableResult
    static func restore(_ items: [NSPasteboardItem]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }
}
