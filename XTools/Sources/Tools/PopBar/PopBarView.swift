import SwiftUI
import AppKit

/// The PopBar settings page: enable the popup, grant Accessibility, edit the
/// configurable actions, configure models, and preview the capsule.
struct PopBarView: View {

    @ObservedObject private var store: PopBarStore
    @ObservedObject private var llm: PopBarLLMStore
    @ObservedObject private var actions: ActionStore

    @State private var editingAction: PopBarActionConfig?
    @State private var keyDraft = ""
    @State private var keyError: String?

    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: PopBarStore, llm: PopBarLLMStore, actions: ActionStore) {
        _store = ObservedObject(wrappedValue: store)
        _llm = ObservedObject(wrappedValue: llm)
        _actions = ObservedObject(wrappedValue: actions)
    }

    var body: some View {
        Form {
            statusSection
            if !store.isTrusted { permissionSection }
            actionsSection
            modelSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.popbar.title"))
        .onAppear { store.refreshTrust() }
        .onReceive(trustPoll) { _ in store.refreshTrust() }
        .sheet(item: $editingAction) { action in
            ActionEditorView(action: action, llm: llm) { saved in
                if actions.actions.contains(where: { $0.id == saved.id }) {
                    actions.update(saved)
                } else {
                    actions.add(saved)
                }
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })) {
                featureLabel("text.bubble.fill", .indigo,
                             L("popbar.enable.title"), L("popbar.enable.subtitle"))
            }
            LabeledContent {
                HStack(spacing: 6) {
                    StatusDot(active: running)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(running ? .green : .orange)
                }
            } label: {
                iconLabel("dot.radiowaves.left.and.right", running ? .green : .gray, L("popbar.status.title"))
            }
        }
    }

    private var running: Bool { store.isEnabled && store.isTrusted }
    private var statusText: String {
        if !store.isTrusted { return L("popbar.status.needsPermission") }
        return store.isEnabled ? L("popbar.status.on") : L("popbar.status.off")
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("popbar.perm.title")).fontWeight(.medium)
                    Text(L("popbar.perm.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(L("popbar.perm.grant")) { store.requestPermission() }
                Button(L("popbar.perm.open")) { store.openAccessibilitySettings() }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text(L("popbar.perm.header"))
        }
    }

    // MARK: - Actions (editable)

    private var actionsSection: some View {
        Section {
            ForEach(Array(actions.actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 8) {
                    Button { editingAction = action } label: { actionRow(action) }
                        .buttonStyle(.plain)
                    reorderControls(index: index)
                }
                .contextMenu {
                    Button(L("popbar.action.edit")) { editingAction = action }
                    Button(L("popbar.action.delete"), role: .destructive) { actions.delete(id: action.id) }
                }
            }

            HStack {
                Button {
                    editingAction = PopBarActionConfig(title: "", iconSymbol: "sparkles", kind: .ai)
                } label: {
                    Label(L("popbar.actions.add"), systemImage: "plus")
                }
                Spacer()
                Button(L("popbar.actions.reset")) { actions.resetToDefaults() }
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { store.autoExpandHeight },
                                 set: { store.setAutoExpandHeight($0) })) {
                iconLabel("arrow.up.and.down.text.horizontal", .indigo, L("popbar.autoheight.label"))
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { store.resultFontSize },
                                          set: { store.setResultFontSize($0) }),
                           in: PopBarPreferences.resultFontSizeRange, step: 1)
                        .frame(maxWidth: 180)
                    Text("\(Int(store.resultFontSize))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                }
            } label: {
                iconLabel("textformat.size", .indigo, L("popbar.fontsize.label"))
            }
            Button { store.showPreview() } label: {
                Label(L("popbar.preview.button"), systemImage: "eye")
            }
        } header: {
            Text(L("popbar.actions.header"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("popbar.actions.footer2"))
                Text(L("popbar.autoheight.footer"))
                Text(L("popbar.fontsize.footer"))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Up/down chevrons to reorder a row, disabled at the list ends. Each button
    /// hit-tests across its full padded bounds, not just the glyph.
    @ViewBuilder
    private func reorderControls(index: Int) -> some View {
        let count = actions.actions.count
        VStack(spacing: 0) {
            reorderButton(symbol: "chevron.up", help: L("popbar.action.moveUp"),
                          enabled: index > 0) {
                // Move this row one slot earlier.
                actions.move(from: IndexSet(integer: index), to: index - 1)
            }
            reorderButton(symbol: "chevron.down", help: L("popbar.action.moveDown"),
                          enabled: index < count - 1) {
                // toOffset is the index *before* the move, so to land after the
                // next row we target index + 2.
                actions.move(from: IndexSet(integer: index), to: index + 2)
            }
        }
    }

    private func reorderButton(symbol: String, help: String, enabled: Bool,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 24, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func actionRow(_ action: PopBarActionConfig) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: action.iconSymbol, color: .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title.isEmpty ? L("popbar.action.untitled") : action.title)
                if action.isAI {
                    Text(modelLabel(action)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            actionTag(action)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func modelLabel(_ action: PopBarActionConfig) -> String {
        if let o = action.modelOverride {
            return "\(LLMConfig.displayName(o.provider)) · \(o.model)"
        }
        return L("popbar.action.defaultModel")
    }

    @ViewBuilder
    private func actionTag(_ action: PopBarActionConfig) -> some View {
        if action.isLocal {
            tag(L("popbar.tag.real"), .green)
        } else if llm.isConfigured(for: action.modelOverride) {
            tag(L("popbar.tag.ai"), .indigo)
        } else {
            tag(L("popbar.tag.needsKey"), .orange)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
    }

    // MARK: - Default model + per-provider key

    private var modelSection: some View {
        Section {
            Picker(selection: Binding(get: { llm.provider }, set: { llm.setProvider($0); keyDraft = "" })) {
                ForEach(LLMConfig.providers, id: \.self) { p in
                    Text(LLMConfig.displayName(p)).tag(p)
                }
            } label: { iconLabel("cpu", .indigo, L("popbar.llm.provider")) }

            LabeledContent {
                TextField(L("popbar.llm.model"),
                          text: Binding(get: { llm.model }, set: { llm.setModel($0) }))
                    .multilineTextAlignment(.trailing).frame(maxWidth: 220)
            } label: { iconLabel("shippingbox", .indigo, L("popbar.llm.model")) }

            Picker(selection: Binding(get: { llm.reasoningEffort }, set: { llm.setReasoningEffort($0) })) {
                ForEach(llm.thinkingOptions, id: \.tag) { opt in Text(opt.label).tag(opt.tag) }
            } label: { iconLabel("brain", .indigo, L("popbar.llm.thinking")) }

            LabeledContent {
                if llm.hasKeyForCurrent {
                    HStack(spacing: 8) {
                        Text(L("popbar.llm.key.saved")).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Button(L("popbar.llm.key.clear")) { llm.clearKey(for: llm.provider) }.controlSize(.small)
                    }
                } else {
                    Text(L("popbar.llm.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                }
            } label: { iconLabel("key", .indigo, String(format: L("popbar.llm.keyFor"), LLMConfig.displayName(llm.provider))) }

            HStack {
                SecureField(L("popbar.llm.key.placeholder"), text: $keyDraft)
                Button(L("popbar.llm.key.save")) {
                    keyError = llm.saveKey(keyDraft, for: llm.provider)
                    if keyError == nil { keyDraft = "" }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(L("popbar.llm.header"))
        } footer: {
            Text(L("popbar.llm.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text(L("popbar.about.body"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
