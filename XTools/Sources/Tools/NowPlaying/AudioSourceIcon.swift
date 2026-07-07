import AppKit

/// UI helpers for an `AudioSource` — shared by the tool's row and the Dashboard
/// card so icon/duration rendering lives in ONE place.
extension AudioSource {

    /// The best real icon for this source: the running app's icon, else the
    /// OWNING `.app` bundle's icon (for helper processes like "Google Chrome
    /// Helper" that have no NSRunningApplication), else the executable's icon,
    /// else a generic audio glyph.
    var appIcon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let ic = app.icon {
            return ic
        }
        if let bp = bundlePath {
            return NSWorkspace.shared.icon(forFile: bp)
        }
        if let p = executablePath {
            return NSWorkspace.shared.icon(forFile: p)
        }
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
    }

    /// Compact elapsed-time label, e.g. "1h 3m", "4m 20s", "9s".
    static func durationText(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
