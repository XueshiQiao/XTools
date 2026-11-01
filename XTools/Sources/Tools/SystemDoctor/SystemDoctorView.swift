import SwiftUI
import AppKit

/// The System Doctor page: read-only inspection of WindowServer compositor load,
/// Mach port holdings across processes, non-standard on-screen window layers
/// (fullscreen overlays / floating glass panels), and high-CPU orphan CLI processes.
struct SystemDoctorView: View {

    @ObservedObject private var store: SystemDoctorStore
    @State private var windowsExpanded = false
    @State private var historyExpanded = false

    init(store: SystemDoctorStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var snap: SystemDoctorSnapshot { store.snapshot }
    private var comp: CompositorMetrics { snap.compositor }

    var body: some View {
        Form {
            overviewSection
            anomaliesSection
            portHoldersSection
            windowLayersSection
            scheduleAndHistorySection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.sysdoc.title"))
        .toolbar {
            ToolbarItem {
                if let toast = store.copiedToast {
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button {
                    store.refresh(recordHistory: true)
                } label: {
                    Label(L("sysdoc.action.scanNow"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear {
            if !snap.isValid && !store.isScanning {
                // Delay briefly so the window-open animation finishes before sampling WindowServer CPU
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !store.snapshot.isValid && !store.isScanning {
                        store.refresh(recordHistory: true)
                    }
                }
            }
        }
    }

    // MARK: - Section 1: Compositor & System Headline

    private var overviewSection: some View {
        Section {
            // Overall status
            LabeledContent {
                if store.isScanning {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(L("sysdoc.status.scanning"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else if snap.isValid {
                    HStack(spacing: 6) {
                        Image(systemName: snap.overallSeverity.symbol)
                            .foregroundStyle(snap.overallSeverity.color)
                        Text(snap.totalAnomalyCount == 0
                             ? L("sysdoc.status.allHealthy")
                             : String(format: L("sysdoc.status.anomaliesFound"), snap.totalAnomalyCount))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(snap.overallSeverity.color)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            } label: {
                featureLabel(
                    "stethoscope",
                    snap.isValid ? snap.overallSeverity.color : .mint,
                    L("sysdoc.headline.status.title"),
                    snap.isValid
                        ? String(format: L("sysdoc.headline.status.updated"), timeText(snap.timestamp))
                        : L("sysdoc.headline.status.sub")
                )
            }

            // WindowServer instantaneous CPU
            LabeledContent {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f%%", comp.cpuPercent))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(comp.cpuSeverity.color)
                    if comp.memoryBytes > 0 {
                        Text(byteText(comp.memoryBytes))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } label: {
                featureLabel(
                    "sparkles.rectangle.stack.fill",
                    comp.cpuSeverity == .healthy ? .blue : comp.cpuSeverity.color,
                    L("sysdoc.headline.wsCPU.title"),
                    displaySubtitle
                )
            }

            // WindowServer Mach ports
            LabeledContent {
                HStack(spacing: 6) {
                    Text(numberText(comp.machPorts))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(comp.portSeverity.color)
                    Text(L("sysdoc.unit.ports"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } label: {
                featureLabel(
                    "point.3.connected.trianglepath.dotted",
                    comp.portSeverity == .healthy ? .purple : comp.portSeverity.color,
                    L("sysdoc.headline.wsPorts.title"),
                    L("sysdoc.headline.wsPorts.sub")
                )
            }

            // Menu bar cross-display replicant load + system idle
            LabeledContent {
                HStack(spacing: 10) {
                    Text(String(format: "MenuSync %.1f%%", comp.loginwindowCPU + comp.menuBarAgentCPU))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle((comp.loginwindowCPU + comp.menuBarAgentCPU) >= 10 ? .orange : .secondary)
                    Text(String(format: "Idle %.0f%%", comp.systemIdlePercent))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            } label: {
                featureLabel(
                    "menubar.rectangle",
                    .teal,
                    L("sysdoc.headline.menubar.title"),
                    L("sysdoc.headline.menubar.sub")
                )
            }
        } header: {
            Text(L("sysdoc.section.overview"))
        } footer: {
            Text(L("sysdoc.section.overview.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displaySubtitle: String {
        guard !comp.displays.isEmpty else { return L("sysdoc.headline.wsCPU.sub") }
        let parts = comp.displays.map { d in
            "\(d.name) (\(d.pointWidth)×\(d.pointHeight) @ \(d.maxRefreshHz)Hz)"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Section 2: Detected Anomalies (Read-Only)

    private var anomaliesSection: some View {
        Section {
            if !snap.isValid {
                Text(store.isScanning ? L("sysdoc.status.scanning") : L("sysdoc.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if snap.totalAnomalyCount == 0 {
                HStack(spacing: 10) {
                    IconTile(symbol: "checkmark.shield.fill", color: .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("sysdoc.anomalies.none.title"))
                            .fontWeight(.medium)
                        Text(L("sysdoc.anomalies.none.sub"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // 1. Port anomalies
                ForEach(snap.portAnomalies) { item in
                    portHolderRow(item, showDiagnosis: true)
                }
                // 2. Window layer anomalies
                ForEach(snap.windowAnomalies) { win in
                    windowSurfaceRow(win, showDiagnosis: true)
                }
                // 3. Runaway / orphan processes
                ForEach(snap.runawayProcesses) { proc in
                    orphanProcessRow(proc)
                }
            }
        } header: {
            Text(L("sysdoc.section.anomalies"))
        }
    }

    // MARK: - Section 3: Top Mach Port Holders

    private var portHoldersSection: some View {
        Section {
            if snap.topPortHolders.isEmpty {
                Text(store.isScanning ? L("sysdoc.status.scanning") : L("sysdoc.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snap.topPortHolders) { item in
                    portHolderRow(item, showDiagnosis: item.severity >= .warning)
                }
            }
        } header: {
            Text(L("sysdoc.section.topPorts"))
        } footer: {
            Text(L("sysdoc.section.topPorts.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func portHolderRow(_ item: PortHolderItem, showDiagnosis: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        if item.severity >= .warning {
                            Image(systemName: item.severity.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(item.severity.color)
                        }
                        Text("\(numberText(item.ports)) \(L("sysdoc.unit.ports"))")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(item.severity >= .warning ? item.severity.color : .primary)
                    }
                    Text(String(format: "CPU %.1f%% · %@", item.cpuPercent, byteText(item.memoryBytes)))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                readOnlyMenu(pid: item.pid, name: item.name, path: item.executablePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: item.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name).fontWeight(.medium)
                        Text("PID \(item.pid)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.role.badgeText)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                    if showDiagnosis {
                        Text(item.diagnosis)
                            .font(.caption)
                            .foregroundStyle(item.severity >= .warning ? item.severity.color : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Section 4: On-Screen Non-Standard Layer Windows (`layer != 0`)

    private var windowLayersSection: some View {
        Section {
            DisclosureGroup(isExpanded: $windowsExpanded) {
                if snap.elevatedWindows.isEmpty {
                    Text(L("sysdoc.win.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snap.elevatedWindows) { win in
                        windowSurfaceRow(win, showDiagnosis: true)
                    }
                }
            } label: {
                HStack {
                    Text(L("sysdoc.section.windows"))
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: L("sysdoc.win.countBadge"), snap.elevatedWindows.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(L("sysdoc.section.windows.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowSurfaceRow(_ win: WindowSurfaceItem, showDiagnosis: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Layer \(win.layer)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(win.severity >= .warning ? win.severity.color : .primary)
                    Text(String(format: "CPU %.1f%% · %d%% %@", win.ownerCPU, win.screenCoveragePercent, L("sysdoc.win.screenArea")))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                readOnlyMenu(pid: win.ownerPID, name: win.ownerName, path: win.executablePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: win.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(win.ownerName).fontWeight(.medium)
                        Text("PID \(win.ownerPID) · Win #\(win.windowID)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if showDiagnosis {
                        Text(win.diagnosis)
                            .font(.caption)
                            .foregroundStyle(win.severity >= .warning ? win.severity.color : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func orphanProcessRow(_ proc: OrphanProcessItem) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "CPU %.1f%%", proc.cpuPercent))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(proc.severity.color)
                    Text(String(format: "PPID %d · %@", proc.ppid, byteText(proc.memoryBytes)))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                readOnlyMenu(pid: proc.pid, name: proc.name, path: proc.executablePath, commandLine: proc.commandLine)
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: proc.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(proc.name).fontWeight(.medium)
                        Text("PID \(proc.pid)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(proc.diagnosis)
                        .font(.caption)
                        .foregroundStyle(proc.severity.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(proc.commandLine)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Section 5: Periodic Read-Only Schedule & History

    private var scheduleAndHistorySection: some View {
        Section {
            Picker(selection: $store.interval) {
                ForEach(SystemDoctorInterval.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            } label: {
                featureLabel(
                    "clock.arrow.2.circlepath",
                    .indigo,
                    L("sysdoc.schedule.title"),
                    L("sysdoc.schedule.sub")
                )
            }

            DisclosureGroup(isExpanded: $historyExpanded) {
                if store.history.isEmpty {
                    Text(L("sysdoc.history.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.history) { entry in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(String(format: "WS %.1f%% · %@ %@", entry.windowServerCPU, numberText(entry.windowServerPorts), L("sysdoc.unit.ports")))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(entry.windowServerCPU >= 40 || entry.windowServerPorts >= 40_000 ? .orange : .secondary)
                                if entry.anomalyCount > 0 {
                                    Text(String(format: L("sysdoc.history.anomalyBadge"), entry.anomalyCount))
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dateTimeText(entry.timestamp))
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                Text(String(format: L("sysdoc.history.topClient"), entry.topPortProcessName, numberText(entry.topPortCount)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        store.clearHistory()
                    } label: {
                        Text(L("sysdoc.history.clear"))
                            .font(.caption)
                    }
                }
            } label: {
                HStack {
                    Text(L("sysdoc.history.header"))
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(store.history.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("sysdoc.section.schedule"))
        }
    }

    // MARK: - Read-only helper menu

    private func readOnlyMenu(pid: pid_t, name: String, path: String?, commandLine: String? = nil) -> some View {
        Menu {
            Button {
                store.copyText("\(pid)", label: "PID \(pid)")
            } label: {
                Label(String(format: L("sysdoc.menu.copyPID"), pid), systemImage: "doc.on.doc")
            }

            if let path, !path.isEmpty {
                Button {
                    store.copyText(path, label: name)
                } label: {
                    Label(L("sysdoc.menu.copyPath"), systemImage: "link")
                }

                Button {
                    store.revealInFinder(path: path)
                } label: {
                    Label(L("sysdoc.menu.revealInFinder"), systemImage: "folder")
                }
            }

            if let cmd = commandLine, !cmd.isEmpty {
                Button {
                    store.copyText(cmd, label: "argv")
                } label: {
                    Label(L("sysdoc.menu.copyCommand"), systemImage: "terminal")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Formatting helpers

    private func numberText(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private func byteText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    private func timeText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
