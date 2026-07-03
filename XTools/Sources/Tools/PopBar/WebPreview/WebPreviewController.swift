import AppKit
import WebKit

/// The floating **mini-browser** that PopBar's web-preview action opens. A single,
/// reused window (v1): re-previewing navigates the same window rather than spawning
/// a new one. Owned by `PopBarWindowManager`.
///
/// Chrome = **Design C "minimal reader bar"**: one thin unified Liquid-Glass strip
/// (same `.menu`/`.behindWindow` material as the LLM result page) that also *is* the
/// title bar. The window's traffic-lights sit inline at its left; nav glyphs
/// (`‹ › ⟳`) follow, the page **title** is centred (its full URL on hover / tooltip,
/// rather than a long address string), and the two actions (copy link / open in the
/// default browser) are pinned to the far right. Controls are quiet "ghost" glyphs
/// that only lift a soft glass pad on hover — chrome recedes, content leads.
///
/// Design choices:
///  - `.fullSizeContentView` + transparent, hidden title so the glass bar reads as a
///    single 44-pt strip with the page flush beneath it.
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

    /// Chrome geometry. `barHeight` is the unified glass strip; `trafficInset` keeps
    /// the nav cluster clear of the window's traffic-lights (which float over the
    /// strip's left because of `.fullSizeContentView`).
    private enum Metrics {
        static let barHeight: CGFloat = 44
        static let trafficInset: CGFloat = 78
        static let edgeInset: CGFloat = 10
        static let gap: CGFloat = 10
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var backButton: NSButton?
    private var forwardButton: NSButton?
    private var titleLabel: NSTextField?
    private var siteIcon: NSImageView?
    private var centerStack: NSStackView?

    /// Open (or navigate) the mini-browser to `url`.
    func open(_ url: URL) {
        let window = ensureWindow()
        // Bring front, THEN activate (macOS 14+ ordering for a menu-bar-app window).
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The traffic-lights are laid out only once the window is on screen; center
        // them in the bar on the next runloop turn.
        DispatchQueue.main.async { [weak self] in self?.centerTrafficLights() }
        Self.log.info("open \(url.absoluteString)")
        updateCenter(url: url, title: nil)
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

        // --- the unified Liquid-Glass reader bar (same material as the result page) ---
        let bar = NSVisualEffectView()
        bar.material = .menu
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let back = makeGlyphButton("chevron.backward", L("popbar.webpreview.back"), #selector(goBack))
        let forward = makeGlyphButton("chevron.forward", L("popbar.webpreview.forward"), #selector(goForward))
        let reload = makeGlyphButton("arrow.clockwise", L("popbar.webpreview.reload"), #selector(reloadPage))
        let copyLink = makeGlyphButton("doc.on.doc", L("popbar.webpreview.copyurl"), #selector(copyURL), accent: true)
        let openExternal = makeGlyphButton("safari", L("popbar.webpreview.openbrowser"), #selector(openInBrowser), accent: true)
        back.isEnabled = false
        forward.isEnabled = false
        self.backButton = back
        self.forwardButton = forward

        let nav = NSStackView(views: [back, forward, reload])
        nav.orientation = .horizontal
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [copyLink, openExternal])
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        // Centred "site glyph + page title"; full URL lives in the tooltip (C = title,
        // not a long address). The title truncates so it never crowds the clusters.
        let icon = NSImageView()
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        self.siteIcon = icon

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .labelColor
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.titleLabel = title

        let center = NSStackView(views: [icon, title])
        center.orientation = .horizontal
        center.spacing = 6
        center.translatesAutoresizingMaskIntoConstraints = false
        center.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.centerStack = center

        // Opaque fill for the BODY region only (below the bar). The window is
        // non-opaque so the bar's `.behindWindow` glass can composite the desktop;
        // without this, the area behind the (initially hidden) web view would show
        // straight through to the desktop — the window would look like it vanished.
        // Kept out from under the bar so the glass still reads.
        let bodyBG = SolidBackgroundView()
        bodyBG.wantsLayer = true
        bodyBG.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(bodyBG)
        container.addSubview(web)
        container.addSubview(bar)
        bar.addSubview(nav)
        bar.addSubview(center)
        bar.addSubview(actions)
        bar.addSubview(hairline)

        // Keep the centred title from overlapping either cluster: hold it at bar centre
        // (breakable) but never let it cross the clusters (required).
        let centerX = center.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centerX.priority = .defaultHigh

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Metrics.barHeight),

            hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            nav.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Metrics.trafficInset),
            nav.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Metrics.edgeInset),
            actions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            center.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centerX,
            center.leadingAnchor.constraint(greaterThanOrEqualTo: nav.trailingAnchor, constant: Metrics.gap),
            center.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -Metrics.gap),

            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            bodyBG.topAnchor.constraint(equalTo: bar.bottomAnchor),
            bodyBG.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyBG.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyBG.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = L("popbar.webpreview.window.title")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.isOpaque = false                 // let the strip's `.behindWindow` material composite
        win.backgroundColor = .clear
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

    /// A quiet "ghost" glyph button: no bezel, dim by default, and it lifts a soft
    /// rounded glass pad + brightens on hover (accent tint for the action buttons).
    /// The whole 28×28 box hit-tests (NSButton covers its full bounds).
    private func makeGlyphButton(_ symbol: String, _ tooltip: String, _ action: Selector, accent: Bool = false) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        let button = HoverGlyphButton(image: image ?? NSImage(), target: self, action: action)
        button.accentOnHover = accent
        button.toolTip = tooltip
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

    /// Vertically center the window's traffic-lights in the glass bar. With
    /// `.fullSizeContentView` the system centers them in the *standard* 28-pt titlebar,
    /// which leaves them a few points above a taller custom bar. We measure their real
    /// center and shift the trio down by the delta — idempotent (re-running lands a
    /// ~0 delta), so it's safe to call on every resize.
    private func centerTrafficLights() {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let close = buttons.first else { return }
        let inWindow = close.convert(close.bounds, to: nil)          // window base coords (origin bottom-left)
        let currentCenterFromTop = window.frame.height - inWindow.midY
        let delta = (Metrics.barHeight / 2) - currentCenterFromTop    // >0 ⇒ still too high, push down
        guard abs(delta) > 0.5 else { return }
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: button.frame.origin.y - delta))
        }
    }

    /// Centre = page title (falls back to host, then the raw URL); the full URL is the
    /// tooltip. Host is appended dimmed when a real title is present.
    private func updateCenter(url: URL?, title: String?) {
        let host = url?.host ?? ""
        let hasTitle = !(title ?? "").isEmpty
        let primary = hasTitle ? title! : (host.isEmpty ? (url?.absoluteString ?? "") : host)

        let attr = NSMutableAttributedString(
            string: primary,
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
        if hasTitle && !host.isEmpty {
            attr.append(NSAttributedString(
                string: "  —  \(host)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 12.5, weight: .regular)]))
        }
        titleLabel?.attributedStringValue = attr

        let tip = url?.absoluteString
        titleLabel?.toolTip = tip
        siteIcon?.toolTip = tip
        centerStack?.toolTip = tip
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
        updateCenter(url: webView.url, title: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshNavButtons()
        updateCenter(url: webView.url, title: webView.title)
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

    /// AppKit re-lays the traffic-lights on resize/key changes — re-center them each time.
    func windowDidResize(_ notification: Notification) { centerTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { centerTrafficLights() }

    // MARK: - WKUIDelegate

    /// `target="_blank"` links would otherwise be dead (no new window is created).
    /// Load them in the same web view instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// A plain opaque fill that tracks light/dark (via `updateLayer` on appearance change).
/// Backs the web-preview body so it never shows the transparent window through to the
/// desktop while the web view is hidden (initial load / navigation reuse).
private final class SolidBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

/// Borderless glyph button that stays quiet until hovered, then lifts a soft rounded
/// glass pad and brightens (accent tint for action buttons). Fixed 28×28; the whole
/// box hit-tests. Used only by the web-preview reader bar.
private final class HoverGlyphButton: NSButton {

    var accentOnHover = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    /// `NSButton(image:target:action:)` funnels through `init(frame:)`, so `commonInit`
    /// runs for it too.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func commonInit() {
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        contentTintColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = (accentOnHover
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.labelColor.withAlphaComponent(0.10)).cgColor
        contentTintColor = accentOnHover ? .controlAccentColor : .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = .secondaryLabelColor
    }

    /// Keep the resting tint correct as enabled-state flips (disabled nav buttons).
    override var isEnabled: Bool {
        didSet {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .secondaryLabelColor
        }
    }
}
