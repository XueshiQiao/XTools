import SwiftUI
import AppKit
import MarkdownUI

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
    /// Whether the result panel auto-grows its height to fit the content (issue
    /// #12). When false (default), the result keeps its fixed compact size. Seeded
    /// from `PopBarPreferences` and kept in sync so an already-open panel honors a
    /// toggle change. Width is always fixed regardless of this flag.
    @Published var autoExpandHeight = PopBarPreferences.autoExpandHeight
    /// The base font size for the result Markdown (issue #14). Seeded from
    /// `PopBarPreferences` and re-seeded on each show + on a live settings change so
    /// an already-open result re-renders at the new size. Headings/code scale as
    /// relative `.em(...)` multiples off this.
    @Published var resultFontSize: Double = PopBarPreferences.resultFontSize
    /// The height the result scroll area should use when auto-expand is ON. The
    /// panel computes this (clamping the view's measured content height against the
    /// popup's own screen — issue #12) and pushes it here; the view applies it.
    /// `nil` means "not yet measured" → fall back to the fixed height.
    @Published var resultContentHeight: CGFloat?

    /// Reports the result content's natural (unclamped) height as SwiftUI measures
    /// it. Wired by the panel, which knows the popup's screen and does the clamping
    /// + window re-fit. This is the single trigger for auto-expand re-fits, so it
    /// covers streaming deltas, one-shot results, and error results alike.
    var onMeasuredContentHeight: ((CGFloat) -> Void)?
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

    /// The result content area's fixed width (always) and its fixed height when
    /// auto-expand is OFF (today's behavior — issue #7). Widened +50% in issue #14.
    private let resultWidth: CGFloat = 450
    private let resultFixedHeight: CGFloat = 130

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
                            // Render the (possibly partial) streaming text as live
                            // Markdown. MarkdownUI parses best-effort, so an unclosed
                            // code fence or half-written list during streaming degrades
                            // gracefully instead of crashing. The copy button still
                            // copies the RAW `text`, not this rendered view.
                            Markdown(text)
                                .markdownTheme(Theme.popBar(baseSize: model.resultFontSize))
                                // The result is untrusted LLM output. MarkdownUI's
                                // default provider would auto-fetch any `![](http…)`
                                // image, so a prompt-injected response could make us
                                // issue arbitrary network requests (tracking pixel /
                                // SSRF) just by being displayed. Render nothing for
                                // images instead.
                                .markdownImageProvider(NoRemoteImageProvider())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measure the rendered content's natural height so the panel can
                    // grow to fit it when auto-expand is ON. The probe sits in a
                    // background so it never affects layout; it only reports a size.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ResultContentHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                    // Anchor used to keep the view pinned to the bottom as text grows.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(width: resultWidth, height: resultHeight)
                // Report the measured natural height to the panel (it clamps against
                // the popup's screen + re-fits the window). This is what makes a
                // one-shot/error result grow too, not just streaming deltas.
                .onPreferenceChange(ResultContentHeightKey.self) { model.onMeasuredContentHeight?($0) }
                .onChange(of: text) { _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
        }
        .padding(10)
    }

    /// The result scroll area's height. OFF (default): exactly today's fixed
    /// `resultFixedHeight`. ON: the panel-computed clamped height (which already
    /// accounts for the popup's screen + min/max), falling back to the fixed height
    /// until the first measurement lands — beyond the cap the content scrolls.
    private var resultHeight: CGFloat {
        guard model.autoExpandHeight else { return resultFixedHeight }
        return model.resultContentHeight ?? resultFixedHeight
    }

    private static let bottomAnchor = "popbar.result.bottom"
}

/// Reports the result content's natural height up to the parent so the panel can
/// size to fit it when auto-expand is ON. Takes the max of reported values within
/// a layout pass (only one probe exists, so this is effectively a pass-through).
private struct ResultContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Markdown image provider

/// Renders nothing for Markdown images. The PopBar result is untrusted LLM
/// output, so we must NOT let MarkdownUI's default provider auto-fetch remote
/// images (a prompt-injected `![](https://tracker/pixel)` would otherwise turn
/// merely displaying the result into an arbitrary network request).
private struct NoRemoteImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { EmptyView() }
}

// MARK: - Markdown theme

private extension Theme {
    /// A compact Markdown theme tuned for the PopBar result panel: tight vertical
    /// margins and modest heading sizes so the popup stays dense and readable in
    /// both light & dark. Colors use system semantic styles so they adapt to
    /// appearance automatically. The body uses `baseSize` (a user setting — issue
    /// #14) and headings/code scale off it as relative `.em(...)` multiples, so the
    /// whole result scales together when the user changes the font size.
    static func popBar(baseSize: CGFloat) -> Theme {
        Theme()
        .text {
            FontSize(baseSize)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.primary.opacity(0.07))
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 6)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.4))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.25))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 5, bottom: 3)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.12))
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .padding(.leading, 8)
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(8)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .markdownMargin(top: 4, bottom: 6)
        }
    }
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
