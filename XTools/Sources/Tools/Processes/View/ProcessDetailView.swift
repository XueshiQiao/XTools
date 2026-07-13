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
                        // Actions live HERE, in deterministic chrome — never in
                        // the AI panel below (HR2.3): model output must not sit
                        // next to a kill button.
                        actionBar(row)
                        Divider()
                        factsSection(row)
                        Divider()
                        // The AI narrative sits strictly BELOW the deterministic
                        // facts (HR9) and never feeds the badges above it.
                        AIPanelView(explainer: store.explainer, llm: store.explainer.llm)
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
                    // Signature badge — deterministic, computed locally, NEVER
                    // from model output (HR9.3).
                    if let sig = store.facts?.signature, store.facts?.row.id == row.id {
                        badge(sig.badge, sig.isWarning ? .orange : .blue)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions (§7)

    /// Quit / Force Quit / Reveal / Copy. For `kernel_task` (pid 0) and `launchd`
    /// (pid 1) all four are DISABLED — not hidden — with a tooltip saying why:
    /// hiding them would read as a rendering bug, disabling them teaches.
    private func actionBar(_ row: ProcRow) -> some View {
        let protected = !row.canTerminate          // pid 0 / pid 1
        let hasPath = row.executablePath != nil
        return HStack(spacing: 6) {
            Button {
                store.requestQuit(row)
            } label: {
                Label(L("processes.action.quit"), systemImage: "xmark.circle")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(protected)
            .help(protected ? L("processes.action.protected") : L("processes.action.quit.help"))

            Button {
                store.requestForceQuit(row)
            } label: {
                Label(L("processes.action.forceQuit"), systemImage: "xmark.octagon")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(protected)
            .help(protected ? L("processes.action.protected") : L("processes.action.forceQuit.help"))

            Spacer(minLength: 0)

            Button {
                store.revealInFinder(row)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(protected || !hasPath)
            .help(protected ? L("processes.action.protected") : L("processes.action.reveal"))

            Button {
                store.copyPath(row)
            } label: {
                Image(systemName: "doc.on.doc")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(protected || !hasPath)
            .help(protected ? L("processes.action.protected") : L("processes.action.copyPath"))
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

            // Slow facts (signature, launchd, argv) arrive asynchronously —
            // computed locally, never from the model (HR9.1).
            if let facts = store.facts, facts.row.id == row.id {
                factRow(L("processes.facts.signature"), signatureSummary(facts))
                if let bundleID = facts.bundleID {
                    factRow(L("processes.facts.bundleid"), bundleID, monospaced: true, selectable: true)
                }
                if let label = facts.launchdLabel {
                    factRow(L("processes.facts.launchd"), label, monospaced: true, selectable: true)
                }
                if !row.isKernelTask {
                    factRow(L("processes.facts.args"), argsSummary(facts),
                            monospaced: true, selectable: true)
                }
                if !facts.parents.isEmpty {
                    factRow(L("processes.facts.parents"),
                            facts.parents.map { "\($0.name) (\($0.pid))" }.joined(separator: " ‹ "))
                }
            } else if !row.isKernelTask {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("processes.facts.computing"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
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

    /// One line of signature truth: badge text plus Team ID and notarization
    /// when they exist. All from `SecStaticCode`, none from a model.
    private func signatureSummary(_ facts: ProcFacts) -> String {
        guard let sig = facts.signature else {
            return facts.row.isKernelTask ? L("processes.facts.noPath") : L("processes.sign.unreadable")
        }
        var parts = [sig.badge]
        if let team = sig.teamID { parts.append(String(format: L("processes.sign.team"), team)) }
        if let notarized = sig.isNotarized {
            parts.append(notarized ? L("processes.sign.notarized") : L("processes.sign.notNotarized"))
        }
        return parts.joined(separator: " · ")
    }

    /// Raw argv for the LOCAL facts panel (Activity Monitor shows the same; this
    /// never leaves the machine — the AI payload goes through the redactor).
    private func argsSummary(_ facts: ProcFacts) -> String {
        guard let argv = facts.argv else { return L("processes.facts.args.unreadable") }
        guard argv.hasMeaningfulArguments else { return L("processes.facts.args.none") }
        let joined = argv.values.dropFirst().joined(separator: " ")
        return joined.count > 400 ? String(joined.prefix(400)) + "…" : joined
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
