import SwiftUI

/// The "what gets sent" area of the AI panel — ONE component with two shapes
/// (HR1.1, D2, §5.5):
///
/// 1. **Standing disclosure** — an always-available expandable section showing
///    the literal payload JSON: a live preview before anything is sent, the
///    archived actual payload afterwards. It never goes away.
/// 2. **Confirmation gate** — the same area in its expanded "confirm" state,
///    carrying (only when they apply) the first-run notice, the argv toggle with
///    the redacted arguments in plain sight, "remember my choice", and the
///    confirm button. One inline panel; never two stacked dialogs.
struct PayloadDisclosureView: View {

    @ObservedObject var explainer: ProcExplainer
    @State private var expanded = false

    private var confirming: Bool { explainer.phase == .confirming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirming {
                gate
            } else {
                standingHeader
            }
            if expanded || confirming {
                jsonBox
                redactionFootnotes
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(confirming ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - Standing form

    private var standingHeader: some View {
        HStack(spacing: 6) {
            // The WHOLE row toggles the disclosure, not just the chevron glyph.
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(explainer.didSend ? L("processes.ai.payload.sent")
                                           : L("processes.ai.payload.will"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // §5.5 row 5: a remembered choice sends directly, but the decision
            // stays one click away.
            if explainer.hasMeaningfulArguments && explainer.phase != .streaming {
                Button(L("processes.ai.change")) { explainer.reopenGate() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Confirmation gate

    private var gate: some View {
        VStack(alignment: .leading, spacing: 10) {
            if explainer.gateShowsFirstRunNotice {
                Label {
                    Text(String(format: L("processes.ai.notice"), providerName))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if explainer.gateShowsArgvToggle {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $explainer.includeArgv) {
                        Text(L("processes.ai.gate.includeArgv"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    // The redacted argv in plain sight — the user decides while
                    // LOOKING at what would go out, not from memory.
                    if !explainer.redactedArgv.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(explainer.redactedArgv.joined(separator: " "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(explainer.includeArgv ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .textSelection(.enabled)
                                .padding(6)
                        }
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                    }

                    Toggle(isOn: $explainer.rememberChoice) {
                        Text(L("processes.ai.gate.remember"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button(L("processes.ai.gate.confirm")) { explainer.confirmGate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L("processes.ai.gate.cancel")) { explainer.dismissGate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - JSON + footnotes

    private var jsonBox: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            Text(explainer.previewJSON)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var redactionFootnotes: some View {
        if let red = explainer.redaction, red.redactedCount > 0 {
            footnote(String(format: L("processes.ai.payload.redacted"), red.redactedCount), symbol: "eye.slash")
        }
        if let red = explainer.redaction, red.wasTruncated {
            footnote(L("processes.ai.payload.truncated"), symbol: "scissors")
        }
        if explainer.argvWithheld {
            footnote(L("processes.ai.payload.withheld"), symbol: "minus.circle")
        }
    }

    private func footnote(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var providerName: String {
        guard let config = explainer.llm.defaultConfig() else { return "—" }
        return "\(LLMConfig.displayName(config.provider)) (\(config.model))"
    }
}
