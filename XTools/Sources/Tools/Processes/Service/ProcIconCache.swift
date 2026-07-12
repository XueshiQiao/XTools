import AppKit
import SwiftUI

/// Icon for a process row, memoized.
///
/// Resolving an icon is a LaunchServices / disk hit — it must never run per-row
/// per-render with ~800 rows refreshing every few seconds.
///
/// **Keyed by executable path, deliberately NOT by pid.** `PortsStore` caches by
/// `pid_t`, which is wrong for a long-lived list: pids get recycled, so a cached
/// entry can hand a dead process's icon to whatever inherits its pid. Keying by
/// path also collapses the ~60 `Google Chrome Helper` processes into a single
/// resolution instead of 60.
///
/// Main-thread only by convention, like the rest of the SwiftUI/AppKit layer.
final class ProcIconCache {

    private var cache: [String: NSImage] = [:]
    private var fallback: NSImage?

    /// Icon for a row. Cheap after the first call for a given executable path.
    func icon(for row: ProcRow) -> NSImage {
        guard let path = row.executablePath, !path.isEmpty else { return systemFallback() }
        if let hit = cache[path] { return hit }

        let image: NSImage
        if let bundle = row.owningAppBundlePath {
            // The owning .app's icon — what the user recognizes. A helper buried in
            // Chrome's bundle should wear Chrome's icon, not a generic binary icon.
            image = NSWorkspace.shared.icon(forFile: bundle)
        } else {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        cache[path] = image
        return image
    }

    /// For `kernel_task` and anything whose path we could not resolve.
    private func systemFallback() -> NSImage {
        if let f = fallback { return f }
        let img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        fallback = img
        return img
    }

    /// Bound the cache. Called when the tool goes away; paths are stable, so this
    /// is about not holding icons for binaries that no longer run, not correctness.
    func clear() { cache.removeAll(keepingCapacity: false) }
}
