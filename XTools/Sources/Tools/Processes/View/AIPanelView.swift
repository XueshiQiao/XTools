import SwiftUI
import MarkdownUI

/// The AI half of the detail pane — strictly BELOW the deterministic facts
/// (HR9). It renders the streamed Markdown answer, the follow-up box, and the
/// payload disclosure. It deliberately contains **no action buttons of any
/// kind** (no kill, no reveal — HR2.3), and links in the model's output do not
/// open: the text is untrusted.
struct AIPanelView: View {

    @ObservedObject var explainer: ProcExplainer
    /// Observed so a key added on the Models page flips the button back live.
    @ObservedObject var llm: LLMService
    @EnvironmentObject private var appState: AppState

    @State private var followUp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !explainer.isConfigured {
                configureButton
            } else if !explainer.hasFacts {
                collectingRow
            } else {
                PayloadDisclosureView(explainer: explainer)
                content
            }

            // The standing caveat (HR9.2). Always there — not a dismissible toast.
            Label {
                Text(L("processes.ai.disclaimer"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(Color.purple)
            Text(L("processes.ai.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if explainer.fromCache {
                Text(L("processes.ai.cached"))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - States

    /// No model configured → one honest button that routes to the Models page.
    /// No confirmation gate on this path — there is nothing to send yet.
    private var configureButton: some View {
        Button {
            appState.selection = .models
        } label: {
            Label(L("processes.ai.configure"), systemImage: "brain.head.profile")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var collectingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(L("processes.ai.collecting"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch explainer.phase {
        case .idle:
            analyzeButton
        case .confirming:
            // The gate itself lives inside PayloadDisclosureView (one panel).
            EmptyView()
        case .streaming:
            answerBlock
            HStack {
                Button {
                    explainer.cancel()
                } label: {
                    Label(L("processes.ai.stop"), systemImage: "stop.circle")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        case .done:
            answerBlock
            followUpField
        case .stopped:
            answerBlock
            Text(L("processes.ai.stopped"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            followUpField
        case .failed(let message):
            if !explainer.answer.isEmpty { answerBlock }
            errorBox(message)
        }
    }

    private var analyzeButton: some View {
        Button {
            explainer.analyzeTapped()
        } label: {
            Label(L("processes.ai.analyze"), systemImage: "sparkles")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .controlSize(.regular)
    }

    // MARK: - Answer + follow-ups

    @ViewBuilder
    private var answerBlock: some View {
        if explainer.answer.isEmpty && explainer.phase == .streaming {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("processes.ai.waiting"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if !explainer.answer.isEmpty {
            markdown(explainer.answer)
        }

        ForEach(explainer.turns) { turn in
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(turn.question)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if turn.answer.isEmpty && turn.isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    markdown(turn.answer)
                }
            }
            .padding(.top, 2)
        }
    }

    private func markdown(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(.processesAI)
            // Untrusted output: never auto-fetch images (tracking pixel / SSRF)…
            .markdownImageProvider(NoRemoteMarkdownImageProvider())
            // …and links do not open (HR2.3). The text stays selectable, so a
            // user who really wants a URL can copy it deliberately.
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .textSelection(.enabled)
    }

    private var followUpField: some View {
        HStack(spacing: 6) {
            TextField(L("processes.ai.followUp.prompt"), text: $followUp)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(sendFollowUp)
            Button(action: sendFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(followUp.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sendFollowUp() {
        let q = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        followUp = ""
        explainer.askFollowUp(q)
    }

    // MARK: - Error (readable, in-panel — never a system alert)

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.orange)
            }
            Button(L("processes.ai.retry")) { explainer.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Markdown support

/// Renders nothing for Markdown images — same defence as PopBar's result view.
private struct NoRemoteMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { EmptyView() }
}

private extension Theme {
    /// Compact theme for the detail pane: small type, tight margins, semantic
    /// colors that adapt to light/dark automatically.
    static let processesAI = Theme()
        .text {
            FontSize(12)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.primary.opacity(0.07))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.secondary)   // links are inert here; don't dress them as live
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 6)
        }
        .heading1 { c in
            c.label.markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.15)) }
        }
        .heading2 { c in
            c.label.markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.08)) }
        }
        .heading3 { c in
            c.label.markdownMargin(top: 5, bottom: 3)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
        }
        .listItem { c in
            c.label.markdownMargin(top: 1, bottom: 1)
        }
}
