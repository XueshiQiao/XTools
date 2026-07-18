import SwiftUI
import AppKit

/// The PopBar settings page: enable the popup, grant Accessibility, edit the
/// configurable actions, and preview the capsule. The model/provider/key config
/// now lives on the shared **AI Models** page (`ModelsPage`); this page only reads
/// the shared `LLMService` to show whether an action's provider is configured.
struct PopBarView: View {

    @ObservedObject private var store: PopBarStore
    @ObservedObject private var llm: LLMService
    @ObservedObject private var actions: ActionStore

    @State private var editingAction: PopBarActionConfig?
    @State private var previewFallback = PopBarPreferences.previewFallbackToSearch
    @State private var previewEngine = PopBarPreferences.previewSearchEngine
    /// Set when registering the OCR hotkey failed (combo taken) so the field shows a hint.
    @State private var ocrHotKeyError = false

    private let trustPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: PopBarStore, llm: LLMService, actions: ActionStore) {
        _store = ObservedObject(wrappedValue: store)
        _llm = ObservedObject(wrappedValue: llm)
        _actions = ObservedObject(wrappedValue: actions)
    }

    var body: some View {
        Form {
            statusSection
            if !store.isTrusted { permissionSection }
            ocrSection
            actionsSection
            if actions.actions.contains(where: { $0.kind == .webPreview }) {
                webPreviewSection
            }
            resultSection
            displaySection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.popbar.title"))
        .onAppear { store.refreshTrust() }
        .onDisappear { store.dismissPreview() }   // don't leave the live tuning preview orphaned
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

    // MARK: - Screenshot OCR

    private var ocrSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.screenOCREnabled },
                                 set: { ocrHotKeyError = !store.setScreenOCREnabled($0) })) {
                featureLabel("viewfinder", .indigo,
                             L("popbar.ocr.enable.title"), L("popbar.ocr.enable.subtitle"))
            }

            if store.screenOCREnabled {
                LabeledContent {
                    HotKeyRecorderField(combo: store.screenOCRHotKey) { combo in
                        ocrHotKeyError = !store.setScreenOCRHotKey(combo)
                    }
                } label: {
                    iconLabel("command", .indigo, L("popbar.ocr.hotkey.label"))
                }
                if ocrHotKeyError {
                    Text(L("popbar.ocr.hotkey.occupied"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: Binding(get: { store.screenOCRAutoCopy },
                                     set: { store.setScreenOCRAutoCopy($0) })) {
                    iconLabel("doc.on.clipboard", .indigo, L("popbar.ocr.autocopy.label"))
                }

                if !store.isScreenRecordingAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("popbar.ocr.perm.title")).fontWeight(.medium)
                                Text(L("popbar.ocr.perm.body"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack {
                            Button(L("popbar.ocr.perm.grant")) { store.requestScreenRecording() }
                            Button(L("popbar.ocr.perm.open")) { store.openScreenRecordingSettings() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        } header: {
            Text(L("popbar.ocr.header"))
        } footer: {
            Text(L("popbar.ocr.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions (editable)

    // MARK: - Actions

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
        } header: {
            Text(L("popbar.actions.header"))
        } footer: {
            Text(L("popbar.actions.footer2"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Web preview (link fallback)

    private var webPreviewSection: some View {
        Section {
            Toggle(isOn: $previewFallback) {
                iconLabel("magnifyingglass", .indigo, L("popbar.webpreview.fallback"))
            }
            .onChange(of: previewFallback) { PopBarPreferences.previewFallbackToSearch = $0 }
            if previewFallback {
                Picker(selection: $previewEngine) {
                    ForEach(PreviewSearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    iconLabel("globe", .indigo, L("popbar.webpreview.engine"))
                }
                .onChange(of: previewEngine) { PopBarPreferences.previewSearchEngine = $0 }
            }
        } header: {
            Text(L("popbar.webpreview.section"))
        } footer: {
            Text(L("popbar.webpreview.fallback.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        Section {
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
        } header: {
            Text(L("popbar.result.header"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("popbar.autoheight.footer"))
                Text(L("popbar.fontsize.footer"))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Display style (capsule / wheel / liquid)

    private var displaySection: some View {
        Section {
            LabeledContent {
                Picker("", selection: Binding(get: { store.style }, set: { store.setStyle($0) })) {
                    Text(L("popbar.style.capsule")).tag(PopBarStyle.capsule)
                    Text(L("popbar.style.wheel")).tag(PopBarStyle.wheel)
                    Text(L("popbar.style.liquid")).tag(PopBarStyle.liquidGlass)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            } label: {
                iconLabel("circle.hexagongrid", .indigo, L("popbar.style.label"))
            }
            // The wheel + liquid-glass styles share these geometry/content knobs; the
            // capsule has none. Changing any of them updates the live preview in place.
            if store.style.isWheel {
                wheelRadiusRow(label: L("popbar.wheel.outer"), symbol: "circle.circle",
                               value: store.wheelOuterRadius, range: PopBarPreferences.wheelOuterRadiusRange) {
                    store.setWheelOuterRadius($0)
                }
                wheelRadiusRow(label: L("popbar.wheel.inner"), symbol: "smallcircle.circle",
                               value: store.wheelInnerRadius, range: PopBarPreferences.wheelInnerRadiusRange) {
                    store.setWheelInnerRadius($0)
                }
                Toggle(isOn: Binding(get: { store.wheelShowIcons }, set: { store.setWheelShowIcons($0) })) {
                    iconLabel("square.grid.2x2", .indigo, L("popbar.wheel.showIcons"))
                }
                Toggle(isOn: Binding(get: { store.wheelShowLabels }, set: { store.setWheelShowLabels($0) })) {
                    iconLabel("textformat", .indigo, L("popbar.wheel.showLabels"))
                }
                Toggle(isOn: Binding(get: { store.wheelAutoHideOnExit }, set: { store.setWheelAutoHideOnExit($0) })) {
                    iconLabel("cursorarrow.motionlines", .indigo, L("popbar.wheel.autoHide"))
                }
            }
            Button { store.showPreview() } label: {
                Label(L("popbar.preview.button"), systemImage: "eye")
            }
        } header: {
            Text(L("popbar.display.header"))
        } footer: {
            Text(L("popbar.style.footer"))
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

    /// A labeled radius slider for the wheel geometry settings (px value shown).
    private func wheelRadiusRow(label: String, symbol: String, value: Double,
                                range: ClosedRange<Double>,
                                onChange: @escaping (Double) -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range, step: 1)
                    .frame(maxWidth: 180)
                Text("\(Int(value))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        } label: {
            iconLabel(symbol, .indigo, label)
        }
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
        } else if llm.isConfigured(forProvider: action.modelOverride?.provider ?? llm.settings.provider) {
            tag(L("popbar.tag.ai"), .indigo)
        } else {
            tag(L("popbar.tag.needsKey"), .orange)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
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
