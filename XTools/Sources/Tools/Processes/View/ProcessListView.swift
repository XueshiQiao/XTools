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
                HStack(spacing: 6) {
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
        // The memory column's HEADER depends on which metric is in the rows, so the
        // table must be rebuilt when the mode flips (footprint ⇄ resident) — the
        // number and its name must never disagree.
        .id(store.memoryMetric == .footprint ? "footprint" : "resident")
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
