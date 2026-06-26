import SwiftUI
import AppKit

/// The PopBar settings page: enable the popup, grant Accessibility, configure the
/// AI model, preview the capsule, and see which actions it offers.
struct PopBarView: View {

    @ObservedObject private var store: PopBarStore
    @ObservedObject private var llm: PopBarLLMStore

    @State private var keyDraft = ""
    @State private var keyError: String?

    /// Poll the Accessibility grant so the UI reflects changes made in System
    /// Settings without a relaunch.
    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: PopBarStore, llm: PopBarLLMStore) {
        _store = ObservedObject(wrappedValue: store)
        _llm = ObservedObject(wrappedValue: llm)
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

    // MARK: - Actions preview

    private var actionsSection: some View {
        Section {
            ForEach(store.actions) { action in
                HStack(spacing: 10) {
                    IconTile(symbol: action.symbol, color: .indigo)
                    Text(action.title)
                    Spacer()
                    actionTag(action)
                }
            }
            Button { store.showPreview() } label: {
                Label(L("popbar.preview.button"), systemImage: "eye")
            }
        } header: {
            Text(L("popbar.actions.header"))
        } footer: {
            Text(L("popbar.actions.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionTag(_ action: PopBarAction) -> some View {
        if action.isLocal {
            tag(L("popbar.tag.real"), .green)
        } else if llm.isConfigured {
            tag(L("popbar.tag.ai"), .indigo)
        } else {
            tag(L("popbar.tag.fake"), .orange)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
    }

    // MARK: - Model (LLM)

    private var modelSection: some View {
        Section {
            Picker(selection: Binding(get: { llm.provider }, set: { llm.setProvider($0) })) {
                ForEach(LLMConfig.providers, id: \.self) { p in
                    Text(LLMConfig.displayName(p)).tag(p)
                }
            } label: { iconLabel("cpu", .indigo, L("popbar.llm.provider")) }

            LabeledContent {
                TextField(L("popbar.llm.model"),
                          text: Binding(get: { llm.model }, set: { llm.setModel($0) }))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
            } label: { iconLabel("shippingbox", .indigo, L("popbar.llm.model")) }

            Picker(selection: Binding(get: { llm.reasoningEffort },
                                      set: { llm.setReasoningEffort($0) })) {
                ForEach(llm.thinkingOptions, id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            } label: { iconLabel("brain", .indigo, L("popbar.llm.thinking")) }

            // API key
            LabeledContent {
                if llm.hasKey {
                    HStack(spacing: 8) {
                        Text(L("popbar.llm.key.saved"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Button(L("popbar.llm.key.clear")) { llm.clearKey() }.controlSize(.small)
                    }
                } else {
                    Text(L("popbar.llm.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                }
            } label: { iconLabel("key", .indigo, L("popbar.llm.key")) }

            HStack {
                SecureField(L("popbar.llm.key.placeholder"), text: $keyDraft)
                Button(L("popbar.llm.key.save")) {
                    keyError = llm.saveKey(keyDraft)
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
