import AppKit
import ApplicationServices

/// Trigger-time raw material for resolving the URL *associated* with a selection —
/// not just "the selection is a URL string", but "the selected anchor text has an
/// href behind it". Captured the instant the gesture fires (the only moment the
/// focused element / cursor / copied pasteboard are still valid), then consumed by
/// `LinkResolver`.
struct LinkProbe {
    /// The selected plain text (for the text-detector tier).
    let text: String
    /// Cursor location in Cocoa screen coords (bottom-left origin) — for logging.
    let mouseLocation: CGPoint
    /// Top edge of the primary display in Cocoa coords, captured on the main thread,
    /// so `LinkResolver` can flip `mouseLocation` into AX coords (top-left origin)
    /// without touching `NSScreen` off the main thread.
    let screenFlipHeight: CGFloat
    /// The app's focused AX element at trigger time (point/selection tiers).
    let focusedElement: AXUIElement?
    /// The copied `public.html` / `public.rtf` pasteboard data (rich-text tier),
    /// present only on the clipboard-copy path.
    let html: Data?
    let rtf: Data?
}

/// Which tier produced the winning URL.
enum LinkTier: String {
    case t1Text          = "T1 text"
    case t2PointURL      = "T2 point"
    case t3SelectionAttr = "T3 selection"
    case t4RichText      = "T4 richtext"
}

struct LinkResolution {
    let url: URL?
    let tier: LinkTier?
}

/// The ONE place "find the link behind this selection" logic lives. Four
/// independent tiers, layered by reliability:
///  - **T1** `fromText` — `NSDataDetector`: the selection literally *is* a URL.
///  - **T2** `urlUnderPoint` — the AX element under the cursor (or an ancestor) is a
///    link → read its `AXURL`. Handles "selected/hovered anchor text ≠ URL".
///  - **T3** `urlInSelection` — a link run anywhere inside the selection's AX
///    attributed string (WebKit marker range or AppKit range).
///  - **T4** `fromRichText` — an `<a href>` in the copied HTML / RTF.
///
/// For diagnosability (the user asked for detailed logs) ALL four tiers run every
/// time and each logs its extracted content + elapsed time; the winner is then
/// picked by priority **T2 → T3 → T4 → T1** (the "associated link" signals beat the
/// bare-URL-text one).
///
/// NOTE (truthfulness): the four extraction paths are reasoned from the AX / WebKit
/// APIs and the PopClip-lineage tools' known approach; they're validated in this
/// repo by the `PopBar.Link` logs + on-screen result, not asserted blindly.
enum LinkResolver {

    private static let log = FileLog("PopBar.Link")

    // MARK: - Entry

    static func resolve(_ probe: LinkProbe) -> LinkResolution {
        // Privacy: the raw selected text is deliberately NOT logged — a selection can
        // be a password / token / private message, and this file persists. We log its
        // LENGTH plus each tier's extracted URL (the diagnostic content that matters).
        log.info("""
        resolve start — textLen=\(probe.text.count) \
        mouse=(\(fmt(probe.mouseLocation.x)),\(fmt(probe.mouseLocation.y))) \
        hasElem=\(probe.focusedElement != nil) html=\(bytes(probe.html)) rtf=\(bytes(probe.rtf))
        """)

        let t1 = timed(.t1Text) { .ran(fromText(probe.text)) }
        let t2 = timed(.t2PointURL) { .ran(urlUnderPoint(probe.mouseLocation, flipHeight: probe.screenFlipHeight)) }
        let t3 = timed(.t3SelectionAttr) {
            guard let el = probe.focusedElement else { return .skipped("no focused element") }
            return .ran(urlInSelection(of: el))
        }
        let t4 = timed(.t4RichText) {
            guard probe.html != nil || probe.rtf != nil else { return .skipped("no rich pasteboard (AX path)") }
            return .ran(fromRichText(html: probe.html, rtf: probe.rtf))
        }

        // Winner by priority: an explicit anchor→URL (T2/T3) beats a rich-text href
        // (T4) beats a bare URL string (T1).
        let winner: (LinkTier, URL)?
        if let u = t2 { winner = (.t2PointURL, u) }
        else if let u = t3 { winner = (.t3SelectionAttr, u) }
        else if let u = t4 { winner = (.t4RichText, u) }
        else if let u = t1 { winner = (.t1Text, u) }
        else { winner = nil }

        if let (tier, url) = winner {
            log.info("resolved via \(tier.rawValue) → \(url.absoluteString)")
            return LinkResolution(url: url, tier: tier)
        }
        log.info("resolved → nil (no link in selection)")
        return LinkResolution(url: nil, tier: nil)
    }

    // MARK: - Tier runner (times + logs each tier uniformly)

    private enum TierOutput { case ran(URL?); case skipped(String) }

    /// Run one tier, log its content + elapsed ms, and return its URL (nil if it
    /// found nothing or was skipped). Uses a monotonic clock, never `Date`.
    private static func timed(_ tier: LinkTier, _ body: () -> TierOutput) -> URL? {
        let start = DispatchTime.now().uptimeNanoseconds
        let out = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        switch out {
        case .ran(let url):
            log.info("  \(pad(tier.rawValue)) ran     → \(url?.absoluteString ?? "nil")   (\(fmt3(ms))ms)")
            return url
        case .skipped(let reason):
            log.info("  \(pad(tier.rawValue)) skipped (\(reason))   (\(fmt3(ms))ms)")
            return nil
        }
    }

    // MARK: - T1: the selection literally is a URL

    static func fromText(_ text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, isWebURL(url) { return url }
        }
        return nil
    }

    // MARK: - T2: the AX element under the cursor is a link

    static func urlUnderPoint(_ cocoaPoint: CGPoint, flipHeight: CGFloat) -> URL? {
        // AX is top-left origin; Cocoa is bottom-left. Flip against the primary display.
        let axY = flipHeight - cocoaPoint.y
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                systemWide, Float(cocoaPoint.x), Float(axY), &elementRef) == .success,
              let element = elementRef else { return nil }

        // The link may be the hit element itself or an ancestor (anchor text is often
        // a child of the `AXLink`). Walk up a bounded number of parents.
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 8 {
            if let url = axURL(of: el), isWebURL(url) { return url }
            current = axParent(of: el)
            depth += 1
        }
        return nil
    }

    // MARK: - T3: a link run inside the selection's attributed string

    static func urlInSelection(of element: AXUIElement) -> URL? {
        // WebKit path: the selected text-marker range → attributed string.
        if let markerRange = copyAttr(element, "AXSelectedTextMarkerRange"),
           let attr = copyParamAttr(element, "AXAttributedStringForTextMarkerRange", markerRange) as? NSAttributedString,
           let url = firstLink(in: attr) {
            return url
        }
        // AppKit path: the selected range → attributed string.
        if let range = copyAttr(element, kAXSelectedTextRangeAttribute as String),
           let attr = copyParamAttr(element, kAXAttributedStringForRangeParameterizedAttribute as String, range) as? NSAttributedString,
           let url = firstLink(in: attr) {
            return url
        }
        return nil
    }

    // MARK: - T4: an href in the copied rich text

    static func fromRichText(html: Data?, rtf: Data?) -> URL? {
        // HTML via a lightweight `href` scan — deliberately NOT `NSAttributedString(html:)`,
        // which must run on the main thread (it uses WebKit) and this resolver runs
        // off-main.
        if let html, let url = firstHref(inHTML: html) { return url }
        // RTF parsing via `NSAttributedString` is main-thread-safe (no WebKit).
        if let rtf,
           let attr = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil),
           let url = firstLink(in: attr) {
            return url
        }
        return nil
    }

    // MARK: - Attributed-string link extraction (shared by T3 + T4/RTF)

    private static func firstLink(in attributed: NSAttributedString) -> URL? {
        var found: URL?
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, _, stop in
            // AppKit / RTF link attribute.
            if let link = attrs[.link] {
                if let url = link as? URL, isWebURL(url) { found = url; stop.pointee = true; return }
                if let str = link as? String, let url = URL(string: str), isWebURL(url) {
                    found = url; stop.pointee = true; return
                }
            }
            // WebKit AX attributed strings expose links as an `AXLink` element run.
            if let raw = attrs[NSAttributedString.Key("AXLink")] {
                let cf = raw as CFTypeRef
                if CFGetTypeID(cf) == AXUIElementGetTypeID(),
                   let url = axURL(of: (cf as! AXUIElement)), isWebURL(url) {
                    found = url; stop.pointee = true; return
                }
            }
        }
        return found
    }

    private static func firstHref(inHTML data: Data) -> URL? {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        guard let regex = try? NSRegularExpression(
                pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { continue }
            // HTML attributes encode `&` as `&amp;` (and similar), so the raw href must
            // be entity-decoded before URL construction — otherwise a query string like
            // `?a=1&amp;b=2` would open a different URL than the link points to.
            let href = decodeHTMLEntities(String(html[r]))
            if let url = URL(string: href), isWebURL(url) { return url }
        }
        return nil
    }

    /// Decode the HTML entities that appear in copied `href` values — most importantly
    /// `&amp;`, which would otherwise corrupt a query string. Handles the named
    /// essentials plus decimal/hex numeric entities.
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        // Numeric entities first: &#38; (decimal) / &#x26; (hex).
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let all = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in all.reversed() {
                guard let whole = Range(match.range, in: result),
                      let flag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[flag].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(scalar))
            }
        }
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // `&amp;` last, so decoding never fabricates a fresh entity from the result.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - AX helpers

    private static func axURL(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let str = value as? String { return URL(string: str) }
        return nil
    }

    private static func axParent(of element: AXUIElement) -> AXUIElement? {
        guard let ref = copyAttr(element, kAXParentAttribute as String),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyAttr(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyParamAttr(_ element: AXUIElement, _ attribute: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, attribute as CFString, param, &value) == .success else { return nil }
        return value
    }

    // MARK: - Misc

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.0f", v) }
    private static func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func bytes(_ d: Data?) -> String { d.map { "\($0.count)B" } ?? "false" }
    private static func pad(_ s: String) -> String { s.padding(toLength: 13, withPad: " ", startingAt: 0) }
}
