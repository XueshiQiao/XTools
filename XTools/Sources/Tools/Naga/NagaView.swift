import SwiftUI

/// The Naga tool page: a per-button mapping grid (assign each side button a
/// shortcut) plus a compact live monitor showing what the buttons emit.
struct NagaView: View {
    @ObservedObject var store: NagaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            mappingGrid
            Divider()
            monitorSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill").foregroundStyle(.green)
            Text(L("tool.naga.title")).font(.title2.bold())
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(store.listening ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(store.listening ? L("naga.listening") : L("naga.notlistening"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mappingGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("naga.mappings")).font(.headline).padding(.bottom, 10)
            ForEach(store.mappings) { m in
                HStack(spacing: 12) {
                    Text("\(m.index)")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.green.opacity(0.15)))
                    Text(m.sentinelName)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    ShortcutRecorder(
                        shortcut: m.target,
                        isRecording: store.recordingButton == m.index,
                        onToggle: { store.toggleRecording(button: m.index) }
                    )
                    .frame(width: 140)
                    Button {
                        store.setShortcut(nil, forButton: m.index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(L("naga.recorder.clear"))
                    .opacity(m.target == nil ? 0 : 1)
                    .disabled(m.target == nil)
                    Spacer()
                    Toggle("", isOn: enabledBinding(m.index)).labelsHidden()
                }
                .padding(.vertical, 7)
                Divider()
            }
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("naga.recent")).font(.headline)
                Spacer()
                Button(L("naga.clear")) { store.clearCaptures() }
                    .buttonStyle(.borderless)
                    .disabled(store.captures.isEmpty)
            }
            if store.captures.isEmpty {
                Text(L("naga.press.hint")).font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.captures.prefix(20)) { c in
                            HStack(spacing: 10) {
                                Text(c.display)
                                    .font(.system(.callout, design: .rounded).weight(.medium))
                                    .frame(minWidth: 56, alignment: .leading)
                                Text(c.detail).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(c.time, style: .time).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func enabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { store.mappings.first { $0.index == index }?.enabled ?? true },
            set: { store.setEnabled($0, forButton: index) }
        )
    }
}
