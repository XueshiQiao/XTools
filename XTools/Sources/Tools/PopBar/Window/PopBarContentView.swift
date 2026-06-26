import SwiftUI
import AppKit

/// Drives what the capsule shows. The panel/controller mutate `phase`; the view
/// re-renders. Kept separate from the controller so the view is previewable.
final class PopBarPanelModel: ObservableObject {
    enum Phase: Equatable {
        case actions
        case loading
        case result(String)
    }

    @Published var phase: Phase = .actions

    /// Buttons to show (defaults to the built-in set).
    var actions: [PopBarAction] = ActionRegistry.defaults

    /// Wired by the controller.
    var onAction: ((PopBarAction) -> Void)?
    var onCopyResult: ((String) -> Void)?
    var onClose: (() -> Void)?
}

/// The capsule's content: a row of action buttons that transitions to a loading
/// spinner and then a result panel for AI actions.
struct PopBarContentView: View {

    @ObservedObject var model: PopBarPanelModel

    var body: some View {
        content
            .background(VisualEffectBlur())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.16))
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(6) // room for the shadow inside the clear window
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .actions:
            actionsBar
        case .loading:
            loadingBar
        case .result(let text):
            resultPanel(text)
        }
    }

    // MARK: - Actions row

    private var actionsBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider().frame(height: 26).opacity(0.4) }
                CapsuleActionButton(action: action) { model.onAction?(action) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    // MARK: - Loading

    private var loadingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("popbar.loading")).font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Result

    private func resultPanel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 300, height: 130)

            HStack(spacing: 8) {
                Spacer()
                Button { model.onCopyResult?(text) } label: {
                    Label(L("popbar.action.copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }
}

/// A single capsule button: icon over a tiny caption. The WHOLE tile hit-tests
/// (`.contentShape(Rectangle())`), not just the glyph.
private struct CapsuleActionButton: View {
    let action: PopBarAction
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(action.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(width: 52, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.title)
    }
}

/// `NSVisualEffectView` blur behind the capsule.
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
