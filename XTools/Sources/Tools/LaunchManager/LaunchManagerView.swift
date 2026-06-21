import SwiftUI
import AppKit

/// The Launch Manager page. Top to bottom: the Guardian area (status + rules),
/// residual ("ghost") processes with one-tap reap / "add Guardian" (Apple's own
/// services collapsed away), and the searchable launchd inventory for manual
/// stop / disable.
struct LaunchManagerView: View {

    @ObservedObject private var store: LaunchManagerStore
    @ObservedObject private var reaper: GuardianReaper
    @State private var searchText = ""
    @State private var pendingReap: ResidualGroup?
    @State private var appleExpanded = false

    init(store: LaunchManagerStore) {
        _store = ObservedObject(wrappedValue: store)
        _reaper = ObservedObject(wrappedValue: store.reaper)
    }

    var body: some View {
        Form {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            guardianSection
            residualSection
            inventorySection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.launch.title"))
        .searchable(text: $searchText, placement: .toolbar, prompt: L("launch.search.prompt"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { if store.launchItems.isEmpty && store.residualGroups.isEmpty { store.refresh() } }
        .confirmationDialog(
            L("launch.reap.confirm.title"),
            isPresented: Binding(get: { pendingReap != nil }, set: { if !$0 { pendingReap = nil } }),
            presenting: pendingReap
        ) { group in
            Button(L("launch.reap.confirm.action"), role: .destructive) {
                store.reap(group: group); pendingReap = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingReap = nil }
        } message: { group in
            Text(String(format: L("launch.reap.confirm.message"), group.helperCount, group.appName))
        }
    }

    // MARK: - Guardian (status + rules, merged)

    private var guardianSection: some View {
        Section {
            LabeledContent {
                Text(reaper.activeRuleCount > 0
                     ? String(format: L("launch.guardian.activeCount"), reaper.activeRuleCount)
                     : L("launch.guardian.none"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(reaper.activeRuleCount > 0 ? .green : .secondary)
            } label: {
                iconLabel("shield.lefthalf.filled", reaper.activeRuleCount > 0 ? .green : Color(nsColor: .systemGray),
                          L("launch.guardian.title"))
            }
            if let last = reaper.lastEnforcement, last.reaped > 0 {
                Text(String(format: L("launch.guardian.lastReap"), last.reaped))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if reaper.rules.isEmpty {
                Text(L("launch.rules.empty")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(reaper.rules) { ruleRow($0) }
            }
        } header: {
            Text(L("launch.guardian.header"))
        } footer: {
            Text(L("launch.guardian.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruleRow(_ rule: GuardianRule) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.appBundlePath))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                Text(rule.appBundlePath)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in store.toggleRule(rule) }))
                .labelsHidden()
            Button(role: .destructive) { store.deleteRule(rule) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Residual processes

    private var nonAppleResidual: [ResidualGroup] {
        store.residualGroups.filter { $0.classification != .appleSystem }
    }
    private var appleResidual: [ResidualGroup] {
        store.residualGroups.filter { $0.classification == .appleSystem }
    }

    private var residualSection: some View {
        Section {
            if store.residualGroups.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("launch.residual.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nonAppleResidual) { residualRow($0) }
                if !appleResidual.isEmpty {
                    DisclosureGroup(isExpanded: $appleExpanded) {
                        ForEach(appleResidual) { residualRow($0) }
                    } label: {
                        Label(String(format: L("launch.apple.group"), appleResidual.count),
                              systemImage: "gearshape.2.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L("launch.residual.header"))
        } footer: {
            Text(L("launch.residual.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One residual row — single line: icon + name/summary on the left, the
    /// Guardian + Reap actions hard-right. Helper process names show on hover.
    private func residualRow(_ group: ResidualGroup) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: group.appBundlePath))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.appName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    classificationBadge(group.classification)
                    if group.containsRoot {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(String(format: L("launch.residual.helperSummary"), group.helperCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if store.hasRule(for: group) {
                Label(L("launch.guardian.added"), systemImage: "checkmark.shield.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
                    .help(L("launch.guardian.added"))
            } else {
                Button { store.createRule(from: group) } label: {
                    Label(L("launch.guardian.add"), systemImage: "shield")
                }
                .controlSize(.small)
            }
            Button(role: .destructive) { pendingReap = group } label: {
                Label(L("launch.reap"), systemImage: "xmark.bin")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .help(group.helpers.map { $0.name }.joined(separator: ", "))
    }

    // MARK: - Launchd inventory (always visible, live-searchable)

    private func items(_ domain: LaunchItem.Domain) -> [LaunchItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.launchItems.filter { item in
            guard item.domain == domain else { return false }
            guard !q.isEmpty else { return true }
            return item.label.lowercased().contains(q)
                || (item.programPath ?? "").lowercased().contains(q)
                || item.plistPath.lowercased().contains(q)
        }
    }

    private var anyInventoryMatch: Bool {
        LaunchItem.Domain.allCases.contains { !items($0).isEmpty }
    }

    @ViewBuilder
    private var inventorySection: some View {
        ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
            let list = items(domain)
            if !list.isEmpty {
                Section {
                    ForEach(list) { itemRow($0) }
                } header: {
                    Text("\(domainName(domain)) (\(list.count))")
                } footer: {
                    if domain == LaunchItem.Domain.allCases.last {
                        Text(L("launch.inventory.footer")).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if !anyInventoryMatch {
            Section {
                Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty
                     ? L("launch.inventory.empty") : L("launch.inventory.noMatch"))
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("launch.inventory.title"))
            }
        }
    }

    private func itemRow(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if item.isOrphan { badge(L("launch.badge.orphan"), .red) }
                    if item.keepAlive { badge(L("launch.badge.keepAlive"), .orange) }
                    if item.processRunsAsRoot {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                if let program = item.programPath {
                    Text(program).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(L("launch.action.disableCompletely")) { store.disableCompletely(item) }
                Divider()
                Button(L("launch.action.bootout")) { store.bootout(item) }
                Button(L("launch.action.disable")) { store.disablePersistently(item) }
                Divider()
                Button(L("launch.action.revealPlist")) { store.revealInFinder(path: item.plistPath) }
                if item.programExists, let program = item.programPath {
                    Button(L("launch.action.revealProgram")) { store.revealInFinder(path: program) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Small pieces

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.actionMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func classificationBadge(_ c: ResidualGroup.Classification) -> some View {
        switch c {
        case .offender:    return badge(L("launch.class.offender"), .red)
        case .benign:      return badge(L("launch.class.benign"), Color(nsColor: .systemGray))
        case .appleSystem: return badge(L("launch.class.appleSystem"), Color(nsColor: .systemGray))
        case .unknown:     return badge(L("launch.class.unknown"), .orange)
        }
    }

    private func domainName(_ d: LaunchItem.Domain) -> String {
        switch d {
        case .userAgent:    return L("launch.domain.userAgent")
        case .systemAgent:  return L("launch.domain.systemAgent")
        case .systemDaemon: return L("launch.domain.systemDaemon")
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
