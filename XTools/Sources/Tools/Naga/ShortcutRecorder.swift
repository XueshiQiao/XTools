import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A click-to-record shortcut field: click it, press the combo you want, done.
/// Esc cancels. Bound to an optional `Shortcut`.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.shortcut = shortcut
        v.onCapture = { self.shortcut = $0 }
        return v
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        if !view.recording { view.shortcut = shortcut; view.needsDisplay = true }
    }
}

/// The AppKit backing view — first-responder key capture with a rounded field look.
final class RecorderView: NSView {
    var shortcut: Shortcut?
    var onCapture: ((Shortcut?) -> Void)?
    private(set) var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let field = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = recording ? L("naga.recorder.recording")
            : (shortcut?.display ?? L("naga.recorder.empty"))
        let color: NSColor = (shortcut == nil && !recording) ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            needsDisplay = true
            window?.makeFirstResponder(nil)
            return
        }
        capture(event)
    }

    // Fires for modifier combos (e.g. ⌘C) that would otherwise be eaten as menu equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let s = Shortcut(keyCode: event.keyCode, modifiers: mods.rawValue)
        shortcut = s
        recording = false
        needsDisplay = true
        onCapture?(s)
        window?.makeFirstResponder(nil)
    }
}
