import SwiftUI
import AppKit

/// Root page of the Process Insight tool: the process table on the left, the
/// selected process's detail (facts, then the AI explanation) on the right.
struct ProcessesView: View {

    @ObservedObject var store: ProcessesStore
    @ObservedObject var prefs: ProcessesPreferences

    init(store: ProcessesStore) {
        _store = ObservedObject(wrappedValue: store)
        _prefs = ObservedObject(wrappedValue: store.prefs)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ProcessListView(store: store)
                statusBar
            }
            .frame(minWidth: 480)

            ProcessDetailView(store: store)
                .frame(minWidth: 260, idealWidth: 300)
        }
        .navigationTitle(L("tool.processes.title"))
        .searchable(text: $store.query, prompt: Text(L("processes.search.prompt")))
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $prefs.hideSystemProcesses) {
                    Label(L("processes.hideSystem"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .help(L("processes.hideSystem.help"))
            }
            ToolbarItem {
                Picker(L("processes.interval"), selection: $prefs.interval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help(L("processes.interval.help"))
            }
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
        // Sampling runs only while this page is actually on screen. The window is
        // often left open all day, so an unattended tab must not keep paying for a
        // metrics stream nobody is looking at.
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(String(format: L("processes.status.count"), store.rows.count, store.totalCount))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if store.mode == .ps {
                // The fallback metric is a DIFFERENT Activity Monitor column, not a
                // less precise version of the same one. Say so where the number is,
                // rather than letting the user discover it by comparing and losing
                // trust in the tool.
                Label(L("processes.mode.ps"), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L("processes.mode.ps.help"))
            }

            Spacer()

            if let message = store.actionMessage {
                HStack(spacing: 6) {
                    Text(message).font(.system(size: 11))
                    Button { store.actionMessage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
