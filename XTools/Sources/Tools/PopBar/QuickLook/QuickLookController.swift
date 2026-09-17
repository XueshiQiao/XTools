import AppKit
import QuickLookUI

/// The floating **preview window** PopBar's Quick Look action opens. Hosts the
/// system `QLPreviewView`, so whatever Finder can show with the spacebar — images,
/// video, audio, PDF, source code, Office documents, archives' summaries — shows
/// here, with zero per-format code on our side. A type Quick Look has no generator
/// for falls back to its own icon+name+size card, exactly as Finder does.
///
/// Deliberately NOT the system `QLPreviewPanel` (the actual spacebar panel): that
/// one is driven through the responder chain (`acceptsPreviewPanelControl`), which
/// an `LSUIElement` menu-bar app with borderless popup panels can't hand it
/// reliably. Owning the window ourselves also lets it remember its frame, matching
/// how `WebPreviewController` behaves.
///
/// A single window is reused (re-previewing navigates it rather than spawning
/// another), and it is owned by `PopBarWindowManager`.
///
/// The preview VIEW, however, is rebuilt for each item rather than reused. That is
/// what guarantees a playing video or audio track actually stops when you preview
/// something else or close the window: `QLPreviewView.close()` releases the item
/// and its player, and a closed view cannot be re-used.
///
/// Main-thread only (callers invoke `open`/`close` on main).
final class QuickLookController: NSObject, NSWindowDelegate {

    private static let log = FileLog("PopBar.QuickLook")

    private var window: NSWindow?
    private var previewView: QLPreviewView?

    /// Open (or re-point) the preview window at `url`.
    func open(_ url: URL) {
        let window = ensureWindow()
        window.title = url.lastPathComponent
        installPreview(for: url, in: window)
        // Bring front, THEN activate (macOS 14+ ordering for a menu-bar-app window).
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Privacy: log the file NAME only. A full path carries the user's home
        // directory (and often a real name), and this log persists on disk.
        Self.log.info("open \(url.lastPathComponent)")
    }

    /// Hide the window and release the current preview — stops any playing media.
    func close() {
        teardownPreview()
        window?.orderOut(nil)
    }

    // MARK: - Window (built once, reused)

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false   // we keep a strong ref and reuse it
        win.delegate = self                // so the red close button also stops media
        win.contentView = NSView()
        // Restore the remembered frame if any, else center; then keep it autosaved.
        win.center()
        win.setFrameUsingName("PopBarQuickLook")
        win.setFrameAutosaveName("PopBarQuickLook")
        window = win
        return win
    }

    // MARK: - Preview view (rebuilt per item)

    private func installPreview(for url: URL, in window: NSWindow) {
        teardownPreview()
        guard let container = window.contentView else { return }
        guard let view = QLPreviewView(frame: container.bounds, style: .normal) else {
            Self.log.error("QLPreviewView init failed for \(url.lastPathComponent)")
            return
        }
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.previewItem = PreviewItem(url)
        previewView = view
    }

    private func teardownPreview() {
        guard let view = previewView else { return }
        view.close()               // releases the item + any player: media stops here
        view.removeFromSuperview()
        previewView = nil
    }

    // MARK: - NSWindowDelegate

    /// The standard red close button only orders the (retained) window out; make
    /// sure the preview is released too, so a video doesn't keep playing unseen.
    func windowWillClose(_ notification: Notification) {
        teardownPreview()
    }
}

/// Minimal `QLPreviewItem` box — Quick Look needs an object, not a bare URL.
private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(_ url: URL) {
        previewItemURL = url
        previewItemTitle = url.lastPathComponent
    }
}
