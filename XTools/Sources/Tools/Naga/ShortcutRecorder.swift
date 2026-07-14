import SwiftUI

/// Click-to-record shortcut field. The actual key capture happens in the
/// KeySwallower event tap (so it catches even already-registered global hotkeys) —
/// this view only shows state and toggles recording. Click again or press Esc to
/// cancel; press ⌫ while recording to clear.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let isRecording: Bool
    let onToggle: () -> Void

    private var label: String {
        if isRecording { return L("naga.recorder.recording") }
        return shortcut?.display ?? L("naga.recorder.empty")
    }

    var body: some View {
        Button(action: onToggle) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.12)
                                          : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        if isRecording { return .accentColor }
        return shortcut == nil ? .secondary : .primary
    }
}
