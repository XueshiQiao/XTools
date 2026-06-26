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
    /// Whether the capsule is pinned open (ignores auto-dismiss).
    @Published var isPinned = false
    /// Live text shown by the result panel. Kept separate from `phase` so streaming
    /// tokens can update the text WITHOUT re-entering `.result` (which would trigger
    /// a full window re-fit on every token). The result frame is fixed, so the
    /// window stays put; only this string changes as deltas arrive.
    @Published var streamingText = ""

    /// Buttons to show (set by the controller from the user's ActionStore).
    var actions: [PopBarActionConfig] = []

    /// Wired by the controller.
    var onAction: ((PopBarActionConfig) -> Void)?
    var onCopyResult: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?

    /// Push a streaming delta into the live result text (no phase change → no re-fit).
    func updateStreamingText(_ text: String) { streamingText = text }
}

/// The capsule's content: a row of action buttons that transitions to a loading
/// spinner and then a result panel for AI actions.
///
/// Visual crispness: the rounded corners + hairline border are masked at the
/// layer level inside `VisualEffectBlur` and the drop shadow is the panel's
/// native window shadow — not a SwiftUI `.shadow` over a transparent window,
/// which is what produces fuzzy/feathered edges.
struct PopBarContentView: View {

    @ObservedObject var model: PopBarPanelModel

    private let cornerRadius: CGFloat = 11

    var body: some View {
        content
            .background(VisualEffectBlur(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .actions:
            actionsBar
        case .loading:
            loadingBar
        case .result:
            // Text comes from the live `streamingText`, not the phase payload, so
            // streaming deltas update in place without re-fitting the window.
            resultPanel(model.streamingText)
        }
    }

    // MARK: - Actions row

    private var actionsBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { separator }
                CapsuleActionButton(action: action) { model.onAction?(action) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private var separator: some View {
        Divider().frame(height: 26).opacity(0.4)
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
            // Unified chrome toolbar: pin · copy · close all share one button style.
            HStack(spacing: 4) {
                ChromeButton(symbol: model.isPinned ? "pin.fill" : "pin",
                             help: L(model.isPinned ? "popbar.unpin" : "popbar.pin"),
                             active: model.isPinned) { model.onTogglePin?() }
                Spacer()
                ChromeButton(symbol: "doc.on.doc", help: L("popbar.copy.result")) {
                    model.onCopyResult?(text)
                }
                ChromeButton(symbol: "xmark", help: L("popbar.close")) {
                    model.onClose?()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if text.isEmpty {
                            // Pre-first-token: a quiet placeholder so the chrome is
                            // visible immediately without a blank void.
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("popbar.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(text)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Anchor used to keep the view pinned to the bottom as text grows.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(width: 300, height: 130)
                .onChange(of: text) { _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
        }
        .padding(10)
    }

    private static let bottomAnchor = "popbar.result.bottom"
}

/// A single capsule action button: icon over a tiny caption. The WHOLE tile
/// hit-tests (`.contentShape(Rectangle())`), not just the glyph.
private struct CapsuleActionButton: View {
    let action: PopBarActionConfig
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Image(systemName: action.iconSymbol)
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

/// The one small icon button used for pin / copy / close, so they all read as a
/// single family. Whole frame hit-tests; subtle hover + active states.
private struct ChromeButton: View {
    let symbol: String
    let help: String
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.15)
                                     : (hovering ? Color.primary.opacity(0.10) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// `NSVisualEffectView` blur, with rounded corners + a hairline border masked at
/// the layer level so the edge is crisp (no SwiftUI-shadow feathering).
private struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
