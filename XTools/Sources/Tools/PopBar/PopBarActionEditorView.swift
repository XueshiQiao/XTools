import SwiftUI

/// Add/edit sheet for a single configurable action: title, icon, type, prompt,
/// and an optional per-action model override.
struct ActionEditorView: View {

    @State private var draft: PopBarActionConfig
    @ObservedObject private var llm: PopBarLLMStore
    let onSave: (PopBarActionConfig) -> Void
    let onCancel: () -> Void

    init(action: PopBarActionConfig, llm: PopBarLLMStore,
         onSave: @escaping (PopBarActionConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: action)
        _llm = ObservedObject(wrappedValue: llm)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("popbar.editor.title"), text: $draft.title)
                    Picker(L("popbar.editor.kind"), selection: $draft.kind) {
                        Text(L("popbar.editor.kind.ai")).tag(PopBarActionConfig.Kind.ai)
                        Text(L("popbar.editor.kind.copy")).tag(PopBarActionConfig.Kind.copy)
                    }
                }

                Section(L("popbar.editor.icon")) { iconGrid }

                if draft.kind == .ai {
                    Section(L("popbar.editor.prompt")) {
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                    Section { modelOverrideControls }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("popbar.editor.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("popbar.editor.save")) { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 470, height: 600)
    }

    private var isValid: Bool {
        let titleOK = !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
        let promptOK = draft.kind == .copy || !draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        return titleOK && promptOK
    }

    // MARK: - Icon grid

    private var iconGrid: some View {
        LazyVGrid(columns: iconColumns, spacing: 6) {
            ForEach(Self.icons, id: \.self) { symbol in
                Button { draft.iconSymbol = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(draft.iconSymbol == symbol ? Color.accentColor.opacity(0.22)
                                                                 : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(draft.iconSymbol == symbol ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Model override

    @ViewBuilder
    private var modelOverrideControls: some View {
        Toggle(L("popbar.editor.customModel"), isOn: Binding(
            get: { draft.modelOverride != nil },
            set: { on in
                if on {
                    let p = llm.provider
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                } else {
                    draft.modelOverride = nil
                }
            }))

        if let override = draft.modelOverride {
            Picker(L("popbar.llm.provider"), selection: Binding(
                get: { override.provider },
                set: { p in
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                })) {
                ForEach(LLMConfig.providers, id: \.self) { p in Text(LLMConfig.displayName(p)).tag(p) }
            }

            TextField(L("popbar.llm.model"), text: Binding(
                get: { draft.modelOverride?.model ?? "" },
                set: { draft.modelOverride?.model = $0 }))

            Picker(L("popbar.llm.thinking"), selection: Binding(
                get: { draft.modelOverride?.reasoningEffort ?? "none" },
                set: { draft.modelOverride?.reasoningEffort = $0 })) {
                ForEach(LLMConfig.thinkingOptions(for: override.provider), id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }

            if override.provider != "ollama" && !llm.hasKey(for: override.provider) {
                Label(String(format: L("popbar.editor.nokeyWarn"), LLMConfig.displayName(override.provider)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // Curated SF Symbols (all available on macOS 13).
    private static let icons: [String] = [
        "character.bubble", "globe", "globe.asia.australia", "globe.americas",
        "wand.and.stars", "sparkles", "lightbulb", "questionmark.circle",
        "doc.on.doc", "text.bubble", "quote.bubble", "bubble.left.and.bubble.right",
        "textformat", "textformat.abc", "textformat.size", "character.book.closed",
        "book.closed", "pencil", "highlighter", "magnifyingglass",
        "exclamationmark.bubble", "checkmark.circle", "arrow.2.squarepath", "arrow.uturn.backward",
        "scissors", "list.bullet", "brain", "bolt.fill",
        "star.fill", "flag.fill", "tag.fill", "envelope",
        "paperplane.fill", "speaker.wave.2.fill", "mic.fill", "keyboard",
        "function", "number", "percent", "a.magnify",
    ]
}
