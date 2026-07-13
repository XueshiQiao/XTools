import SwiftUI
import AppKit

/// The process table: icon + name, pid, user, CPU%, memory, threads.
///
/// `Table` is NSTableView-backed on macOS, so rows are virtualised — only visible
/// rows render, which is what makes ~800 rows viable at a few-second refresh.
struct ProcessListView: View {

    @ObservedObject var store: ProcessesStore

    var body: some View {
        Table(store.rows, selection: $store.selection, sortOrder: $store.sortOrder) {

            TableColumn(L("processes.col.name"), value: \.name) { row in
                // `pinned` is computed HERE (in the table body, which is the one
                // view observing the store) and passed IN, so the cell itself does
                // not observe the store — it's a pure function of its inputs and
                // won't re-render on every unrelated store change (matches how the
                // Ports list keeps its rows cheap).
                NameCell(row: row, pinned: store.isPinned(pid: row.pid), store: store)
            }
            .width(min: 120, ideal: 170)

            TableColumn(L("processes.col.cpu"), value: \.cpuSort) { row in
                metricText(row.cpuPercent.map { String(format: "%.1f", $0) })
            }
            .width(min: 50, ideal: 56)

            TableColumn(memoryColumnTitle, value: \.memorySort) { row in
                metricText(row.memoryBytes.map(Self.formatBytes))
            }
            .width(min: 68, ideal: 78)

            TableColumn(L("processes.col.threads"), value: \.threadSort) { row in
                metricText(row.threadCount.map(String.init))
            }
            .width(min: 42, ideal: 48)

            TableColumn(L("processes.col.pid"), value: \.pid) { row in
                Text(String(row.pid))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 58)

            TableColumn(L("processes.col.user"), value: \.uid) { row in
                Text(Self.userName(uid: row.uid))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 58, ideal: 72)
        }
        // Right-click actions on a row. Same 2×2 dispatch as the detail pane's
        // buttons (one code path in ProcActions — never a second kill path).
        // pid 0 / pid 1 keep their items DISABLED, not hidden (§7); menus can't
        // show tooltips, so the detail pane's buttons carry the explanation.
        .contextMenu(forSelectionType: ProcID.self) { ids in
            if let id = ids.first, let row = store.row(for: id) {
                contextMenuItems(row)
            }
        }
        // The memory column's HEADER depends on which metric is in the rows, so the
        // table must be rebuilt when the mode flips (footprint ⇄ resident) — the
        // number and its name must never disagree.
        .id(store.memoryMetric == .footprint ? "footprint" : "resident")
    }

    @ViewBuilder
    private func contextMenuItems(_ row: ProcRow) -> some View {
        // Pin sits FIRST deliberately. On this macOS build, dismissing a context
        // menu opened on an INACTIVE window (click elsewhere while it's up) can
        // make SwiftUI perform the first enabled item as if clicked — observed and
        // logged. Quit/Force Quit only ever *request* a confirmation (they set
        // pendingAction, they never signal), so the worst a phantom fire could do
        // is pop a dialog the user then ignores — but putting the sole reversible,
        // no-op-if-ignored action in that slot removes even that annoyance.
        Button(L(store.isPinned(pid: row.pid) ? "processes.action.unpin"
                                              : "processes.action.pin")) {
            store.togglePin(pid: row.pid)
        }
        Divider()
        Button(L("processes.action.quit")) { store.requestQuit(row) }
            .disabled(!row.canTerminate)
        Button(L("processes.action.forceQuit")) { store.requestForceQuit(row) }
            .disabled(!row.canTerminate)
        Divider()
        Button(L("processes.action.reveal")) { store.revealInFinder(row) }
            .disabled(!row.canTerminate || row.executablePath == nil)
        Button(L("processes.action.copyPath")) { store.copyPath(row) }
            .disabled(!row.canTerminate || row.executablePath == nil)
    }

    private var memoryColumnTitle: String {
        store.memoryMetric == .footprint ? L("processes.col.memory")
                                         : L("processes.col.memory.resident")
    }

    /// A metric cell. `nil` means "not sampled yet" and renders as an em dash —
    /// showing 0 would be indistinguishable from a genuinely idle process.
    @ViewBuilder
    private func metricText(_ value: String?) -> some View {
        Text(value ?? "—")
            .monospacedDigit()
            .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 100  { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    /// uid → login name, cached (getpwuid hits Open Directory).
    private static var userNames: [uid_t: String] = [:]
    static func userName(uid: uid_t) -> String {
        if let hit = userNames[uid] { return hit }
        var name = String(uid)
        if let pw = getpwuid(uid), let cName = pw.pointee.pw_name {
            name = String(cString: cName)
        }
        userNames[uid] = name
        return name
    }
}

/// The name column's cell: pin slot + app icon + name + root badge.
///
/// Its own struct with its OWN hover state, so mousing across rows re-renders
/// exactly one cell instead of invalidating the whole table.
private struct NameCell: View {
    let row: ProcRow
    /// Computed by the parent (the table body) and passed in, so the cell does not
    /// subscribe to the store — see the call site.
    let pinned: Bool
    /// A plain reference (NOT `@ObservedObject`): the cell reads the icon cache and
    /// fires pin/action calls, but must not re-render just because the store's
    /// `@Published` state changed. Matches `PortsStore`'s row.
    let store: ProcessesStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            pinButton(pinned: pinned)
            Image(nsImage: store.icons.icon(for: row))
                .resizable().frame(width: 16, height: 16)
            Text(row.name)
                .lineLimit(1).truncationMode(.middle)
            if row.runsAsRoot {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .help(L("processes.badge.root"))
            }
        }
        // Fill the whole cell so hovering anywhere over the name column's row
        // area — not just over the glyphs — surfaces the pin affordance.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// A pinned row always shows the filled pin (the marker doubles as the unpin
    /// button); an unpinned row shows the outline pin while hovered. The slot is
    /// ALWAYS laid out, so the name never shifts when the pin fades in. The
    /// `.contentShape(Rectangle())` on the label makes the entire 16×16 slot
    /// hit-test — a `.plain` button would otherwise respond only on the glyph's
    /// opaque pixels.
    private func pinButton(pinned: Bool) -> some View {
        Button {
            store.togglePin(pid: row.pid)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
                .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pinned || hovering ? 1 : 0)
        .help(L(pinned ? "processes.action.unpin" : "processes.action.pin"))
    }
}
