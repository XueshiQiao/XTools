import SwiftUI
import AppKit
import Carbon.HIToolbox   // cmdKey/shiftKey/optionKey/controlKey masks

/// A click-to-record keyboard-shortcut field. Tapping it enters "recording": the next
/// key-down (with at least one non-shift modifier) becomes the new combo. Tapping again,
/// or pressing Esc, cancels recording without reporting a change.
struct HotKeyRecorderField: View {
    let combo: KeyCombo
    /// Called with the newly recorded combo. The parent persists it and may reject it
    /// (e.g. the combo is already taken) — this view just reports intent.
    let onRecorded: (KeyCombo) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            Text(isRecording ? L("popbar.ocr.hotkey.recording") : combo.display)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 100)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(
                    Capsule().strokeBorder(isRecording ? Color.accentColor
                                                        : Color.primary.opacity(0.15))
                )
                // The whole capsule must hit-test, not just the text glyph.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
        // Cancel recording if the window loses key focus (app switch, a sheet opening,
        // etc.) so the key monitor never keeps swallowing keystrokes in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stopRecording() }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard !isRecording, monitor == nil else { return }
        isRecording = true
        // A local monitor works without the Accessibility permission because the settings
        // window is key; returning nil swallows the event so it never leaks into the app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    /// Tears down the local monitor and leaves recording state. Safe to call repeatedly.
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    /// Handles a key-down while recording. Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mask = carbonModifiers(from: event.modifierFlags)

        // Esc with no modifiers cancels recording.
        if event.keyCode == 53 && mask == 0 {
            stopRecording()
            return nil
        }

        // Require a "real" modifier (⌘/⌥/⌃); ignore bare keys and shift-only so plain
        // typing isn't captured. Keep waiting (swallow) until one arrives.
        let flags = event.modifierFlags
        let hasRealModifier = flags.contains(.command)
            || flags.contains(.option)
            || flags.contains(.control)
        guard hasRealModifier else { return nil }

        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mask)
        stopRecording()
        onRecorded(recorded)
        return nil
    }

    /// Maps AppKit modifier flags to the Carbon mask used by `KeyCombo`.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
