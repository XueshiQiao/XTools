import SwiftUI

/// Titlebar-right accessory for the palette: one click runs tmux-resurrect's
/// save. Lives in the title bar rather than above the tree so it costs no
/// content height — the palette is only 400pt tall by default.
struct TmuxSaveButton: View {

    @ObservedObject var store: TmuxStore

    /// Fixed so the title bar never reflows as the label changes between
    /// "Save session" → "Saving…" → "Saved". Wide enough for the longest
    /// string in both locales.
    private static let capsuleWidth: CGFloat = 104
    private static let capsuleHeight: CGFloat = 20
    private static let sidePadding: CGFloat = 10

    /// Size the title-bar accessory must be given explicitly — see the note at
    /// the `addTitlebarAccessoryViewController` call.
    static let accessorySize = NSSize(width: capsuleWidth + sidePadding * 2, height: 28)

    var body: some View {
        Button(action: { store.saveSession() }) {
            HStack(spacing: 4) {
                icon
                    .frame(width: 11, height: 11)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: Self.capsuleWidth, height: Self.capsuleHeight)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
            // Every pixel of the visible capsule hit-tests, not just the glyph
            // and text — a `.plain` button only responds where content is opaque.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.saveState == .saving)
        .help(helpText)
        .padding(.horizontal, Self.sidePadding)
        .frame(width: Self.accessorySize.width, height: Self.accessorySize.height)
        .animation(.easeInOut(duration: 0.15), value: store.saveState)
    }

    // MARK: - State rendering

    @ViewBuilder
    private var icon: some View {
        switch store.saveState {
        case .idle:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 11, weight: .semibold))
        case .saving:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.55)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var label: String {
        switch store.saveState {
        case .idle:   return L("tmux.save.button")
        case .saving: return L("tmux.save.saving")
        case .saved:  return L("tmux.save.done")
        case .failed: return L("tmux.save.failed")
        }
    }

    private var tint: Color {
        switch store.saveState {
        case .idle:   return .accentColor
        case .saving: return .secondary
        case .saved:  return .green
        case .failed: return .red
        }
    }

    private var helpText: String {
        switch store.saveState {
        case .idle:
            return String(format: L("tmux.save.help"), store.saveKey)
        case .saving:
            return L("tmux.save.help.saving")
        case .saved:
            return L("tmux.save.help.done")
        case .failed(let message):
            return message
        }
    }
}
