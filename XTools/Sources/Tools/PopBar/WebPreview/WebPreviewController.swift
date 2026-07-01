import AppKit
import WebKit

/// The floating **mini-browser** that PopBar's web-preview action opens. A single,
/// reused window (v1): re-previewing navigates the same window rather than spawning
/// a new one. Owned by `PopBarWindowManager`.
///
/// Design choices:
///  - A standard titled window (traffic-lights + resize + a remembered frame via
///    `setFrameAutosaveName`), unlike the non-activating capsule panels — a preview
///    is something you read/scroll/click, so it's a normal key window.
///  - `WKWebsiteDataStore.nonPersistent()` — no cookies/history kept on disk
///    (privacy-first; a quick look shouldn't leave a trail).
///  - A navigation-policy gate that only lets http(s)/about load *inside* the
///    preview, hands external schemes (mailto/tel/…) to the system, and blocks the
///    rest (`javascript:`, `file:`, `data:`) so a page can't pull the preview off
///    the web.
///
/// Main-thread only (callers invoke `open`/`close` on main).
final class WebPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    private static let log = FileLog("PopBar.WebPreview")

    private var window: NSWindow?
    private var webView: WKWebView?
    private var backButton: NSButton?
    private var forwardButton: NSButton?
    private var urlField: NSTextField?

    /// Open (or navigate) the mini-browser to `url`.
    func open(_ url: URL) {
        let window = ensureWindow()
        // Bring front, THEN activate (macOS 14+ ordering for a menu-bar-app window).
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.log.info("open \(url.absoluteString)")
        updateURLField(url)
        // Clear the previous page immediately: when the window is reused for a new
        // link, hide the web view so its stale content isn't shown while the new URL
        // loads. It's revealed again the moment the new navigation commits (below).
        webView?.isHidden = true
        webView?.load(URLRequest(url: url))
    }

    /// Hide the window (kept alive + reused; frame is preserved by the OS). Also quiet
    /// the retained web view so no media / timers / network keep running invisibly
    /// after PopBar is stopped.
    func close() {
        quietWebView()
        window?.orderOut(nil)
    }

    /// Stop the load and navigate to a blank page — halts media / timers / JS / network
    /// on the retained web view without tearing it down (the window is reused).
    private func quietWebView() {
        webView?.stopLoading()
        if let blank = URL(string: "about:blank") { webView?.load(URLRequest(url: blank)) }
    }

    // MARK: - Build (once)

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.translatesAutoresizingMaskIntoConstraints = false
        self.webView = web

        let back = makeButton("chevron.backward", L("popbar.webpreview.back"), #selector(goBack))
        let forward = makeButton("chevron.forward", L("popbar.webpreview.forward"), #selector(goForward))
        let reload = makeButton("arrow.clockwise", L("popbar.webpreview.reload"), #selector(reloadPage))
        let copyLink = makeButton("doc.on.doc", L("popbar.webpreview.copyurl"), #selector(copyURL))
        let openExternal = makeButton("safari", L("popbar.webpreview.openbrowser"), #selector(openInBrowser))
        back.isEnabled = false
        forward.isEnabled = false
        self.backButton = back
        self.forwardButton = forward

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.urlField = field

        let toolbar = NSStackView(views: [back, forward, reload, field, copyLink, openExternal])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(toolbar)
        container.addSubview(web)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            web.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = L("popbar.webpreview.window.title")
        win.contentView = container
        win.isReleasedWhenClosed = false     // we keep a strong ref and reuse it
        win.delegate = self                  // so the red close button also quiets the web view
        // Restore the remembered frame if any, else center; then keep it autosaved.
        win.center()
        win.setFrameUsingName("PopBarWebPreview")
        win.setFrameAutosaveName("PopBarWebPreview")
        self.window = win
        return win
    }

    private func makeButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    // MARK: - Toolbar actions

    @objc private func goBack() { webView?.goBack(); refreshNavButtons() }
    @objc private func goForward() { webView?.goForward(); refreshNavButtons() }
    @objc private func reloadPage() { webView?.reload() }

    @objc private func copyURL() {
        guard let url = webView?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func openInBrowser() {
        guard let url = webView?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshNavButtons() {
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false
    }

    private func updateURLField(_ url: URL?) {
        urlField?.stringValue = url?.absoluteString ?? ""
    }

    // MARK: - WKNavigationDelegate (security + state)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https", "about":
            decisionHandler(.allow)
        case "mailto", "tel", "facetime", "sms":
            NSWorkspace.shared.open(url)      // hand well-known external schemes to the system
            decisionHandler(.cancel)
        case let scheme:
            Self.log.debug("blocked navigation scheme '\(scheme)'")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.isHidden = false   // the new page is now rendering — reveal it
        refreshNavButtons()
        updateURLField(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshNavButtons()
        updateURLField(webView.url)
        if let title = webView.title, !title.isEmpty { window?.title = title }
    }

    // Reveal the web view on failure too, so a blank hidden view isn't left behind.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.isHidden = false
    }

    // MARK: - NSWindowDelegate

    /// The standard red close button only orders the (retained) window out; make sure
    /// the web view is quieted too so nothing keeps running after a manual close.
    func windowWillClose(_ notification: Notification) {
        quietWebView()
    }

    // MARK: - WKUIDelegate

    /// `target="_blank"` links would otherwise be dead (no new window is created).
    /// Load them in the same web view instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
