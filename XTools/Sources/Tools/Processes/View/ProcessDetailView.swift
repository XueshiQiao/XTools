import SwiftUI
import AppKit

/// Detail pane for the selected process.
///
/// Structure (deliberate, see the design doc): everything ABOVE the divider is a
/// deterministic fact computed locally — path, signature, owning launchd job. The
/// AI's prose sits BELOW it and is clearly marked as such. A model that has never
/// heard of a brand-new Apple daemon must not be able to make it look suspicious,
/// and a model that has been talked into vouching for malware must not be able to
/// stamp it "safe" — so verdict-shaped UI only ever renders from the facts.
struct ProcessDetailView: View {

    @ObservedObject var store: ProcessesStore

    var body: some View {
        Group {
            if let row = store.selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(row)
                        Divider()
                        factsSection(row)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private func header(_ row: ProcRow) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: store.icons.icon(for: row))
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(String(format: L("processes.pidLabel"), row.pid))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    if row.isKernelTask {
                        badge(L("processes.badge.kernel"), .orange)
                    } else if row.isAppleSystem {
                        badge(L("processes.badge.apple"), .secondary)
                    }
                    if row.runsAsRoot { badge(L("processes.badge.root"), .red) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Facts

    @ViewBuilder
    private func factsSection(_ row: ProcRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("processes.facts.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            factRow(L("processes.facts.path"),
                    row.executablePath ?? L("processes.facts.noPath"),
                    monospaced: true, selectable: true)
            factRow(L("processes.facts.user"), ProcessListView.userName(uid: row.uid))
            factRow(L("processes.facts.ppid"), String(row.ppid), monospaced: true)
            factRow(L("processes.col.cpu"),
                    row.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "—", monospaced: true)
            factRow(memoryLabel,
                    row.memoryBytes.map(ProcessListView.formatBytes) ?? "—", monospaced: true)
            if let t = row.threadCount {
                factRow(L("processes.col.threads"), String(t), monospaced: true)
            }
            if row.startTime > 0 {
                factRow(L("processes.facts.started"), startedAt(row.startTime))
            }
        }
    }

    private var memoryLabel: String {
        store.memoryMetric == .footprint ? L("processes.col.memory")
                                         : L("processes.col.memory.resident")
    }

    private func startedAt(_ microsSinceEpoch: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(microsSinceEpoch) / 1_000_000)
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .medium
        return fmt.string(from: date)
    }

    @ViewBuilder
    private func factRow(_ label: String, _ value: String,
                         monospaced: Bool = false, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L("processes.detail.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
