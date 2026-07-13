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
            ToolbarItem {
                Menu {
                    Picker(L("processes.argv.policy"), selection: $prefs.argvPolicy) {
                        ForEach(ArgvPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(L("processes.ai.clearCache")) {
                        store.explainer.clearCache()
                        store.actionMessage = L("processes.ai.cacheCleared")
                    }
                } label: {
                    Label(L("processes.settings"), systemImage: "gearshape")
                }
                .help(L("processes.settings.help"))
            }
        }
        // Sampling runs only while this page is actually on screen. The window is
        // often left open all day, so an unattended tab must not keep paying for a
        // metrics stream nobody is looking at. onAppear/onDisappear track the tab;
        // the WindowAccessor hands the store its NSWindow so occlusion (minimised,
        // fully covered, other Space) can stop the pipeline too — a covered window
        // never fires onDisappear.
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .background(WindowAccessor { [weak store] window in store?.attach(window: window) })
        // Confirmation for destructive actions (§7): Force Quit always, and any
        // root / other-uid signal (those also cost an admin password prompt).
        // The pending row is a snapshot — ProcActions re-verifies the pid's
        // fingerprint on confirm, so a stale dialog can never kill a recycled pid.
        .alert(store.pendingAction?.title ?? "",
               isPresented: Binding(get: { store.pendingAction != nil },
                                    set: { if !$0 { store.pendingAction = nil } }),
               presenting: store.pendingAction) { pending in
            Button(pending.confirmTitle, role: .destructive) {
                store.confirmPendingAction()
            }
            Button(L("processes.action.confirm.cancel"), role: .cancel) {
                store.pendingAction = nil
            }
        } message: { pending in
            Text(pending.message)
        }
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

/// Reports the NSWindow this view lives in (and nil when it leaves one), so the
/// store can watch that window's occlusion state. SwiftUI has no native way to
/// reach the hosting window on macOS 13.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onWindow: onWindow) }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
