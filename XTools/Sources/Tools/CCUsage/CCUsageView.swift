import SwiftUI
import AppKit

/// Native macOS visual dashboard for `ccusage daily`:
/// - First-launch automatic download & verification state if `ccusage` is not installed yet
/// - Refresh control bar (5s / 10s / 30s / 60s / Custom seconds / Manual) + live status indicator
/// - Today's Hero Summary (Today's Cost, vs Yesterday delta, Total Tokens, Input/Output/Cache breakdown, All-Time Totals)
/// - Recent N-day Cost Trend interactive bar chart (click any bar to inspect that day's breakdown)
/// - Agent & Model Breakdown for the selected day (with proportional bars)
/// - Expandable Daily History table (showing all recorded days, click to expand per-agent & per-model details)
/// - Bottom footer displaying the current `ccusage` version and a `Check Update` button
struct CCUsageView: View {

    @ObservedObject var store: CCUsageStore
    @ObservedObject var prefs: CCUsagePreferences
    @State private var customSecondsText: String = ""

    init(store: CCUsageStore) {
        _store = ObservedObject(wrappedValue: store)
        _prefs = ObservedObject(wrappedValue: store.prefs)
        _customSecondsText = State(initialValue: "\(store.prefs.customSeconds)")
    }

    var body: some View {
        Form {
            if !store.isBinaryInstalled {
                initialDownloadSection
            } else {
                refreshHeaderSection
                if let err = store.errorMessage, store.report.daily.isEmpty {
                    errorSection(err)
                }
                todayHeroSection
                trendChartSection
                focusedBreakdownSection
                dailyHistorySection
                versionFooterSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.ccusage.title"))
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: $prefs.preset) {
                    ForEach(CCRefreshPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(L("ccusage.refresh.interval.help"))
                .disabled(!store.isBinaryInstalled)

                Button {
                    store.refresh()
                } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || store.isDownloadingBinary)
            }
        }
        .onAppear {
            customSecondsText = "\(prefs.customSeconds)"
            store.start()
        }
        .onDisappear {
            store.stop()
        }
        .background(CCWindowAccessor { [weak store] window in
            store?.attach(window: window)
        })
    }

    // MARK: - 0. Initial Binary Download View

    private var initialDownloadSection: some View {
        Section {
            VStack(spacing: 14) {
                if store.isDownloadingBinary {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.top, 8)
                    Text(L("ccusage.download.title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L("ccusage.download.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.bottom, 8)
                } else if let err = store.downloadErrorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                    Text(L("ccusage.download.failed"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button {
                        store.downloadInitialBinary()
                    } label: {
                        Label(L("ccusage.download.retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 8)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - 1. Refresh & Status Control Strip

    private var refreshHeaderSection: some View {
        Section {
            HStack(spacing: 10) {
                StatusDot(active: prefs.effectiveSeconds != nil)
                if let updated = store.lastUpdated {
                    Text(String(format: L("ccusage.status.updated"), Self.timeFormatter.string(from: updated)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if store.isRefreshing {
                    Text(L("ccusage.status.loading"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("ccusage.status.idle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }

                Spacer()

                if prefs.preset == .custom {
                    HStack(spacing: 4) {
                        Text(L("ccusage.custom.every"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("5", text: $customSecondsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .font(.system(size: 12).monospacedDigit())
                            .onSubmit { commitCustomSeconds() }
                            .onChange(of: customSecondsText) { newValue in
                                if let v = Int(newValue.trimmingCharacters(in: .whitespaces)), v >= 2 {
                                    prefs.customSeconds = v
                                }
                            }
                        Stepper("", value: $prefs.customSeconds, in: 2...3600)
                            .labelsHidden()
                            .onChange(of: prefs.customSeconds) { newVal in
                                customSecondsText = "\(newVal)"
                            }
                        Text(L("ccusage.custom.sec"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func commitCustomSeconds() {
        if let v = Int(customSecondsText.trimmingCharacters(in: .whitespaces)) {
            prefs.customSeconds = max(2, min(3600, v))
        }
        customSecondsText = "\(prefs.customSeconds)"
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 2. Today's Hero Summary + All-Time Summary

    private var todayHeroSection: some View {
        let today = store.todayEntry
        let yesterday = store.yesterdayEntry
        let totals = store.report.totals

        return Section {
            VStack(alignment: .leading, spacing: 14) {
                // Top Row: Today's Cost + vs Yesterday + All-Time Cost
                HStack(alignment: .top, spacing: 20) {
                    // Today Cost Hero
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(L("ccusage.today.cost"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(today.period)
                                .font(.system(size: 11).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.16)))
                                .foregroundStyle(.orange)
                        }
                        Text(CCFormat.cost(today.totalCost))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .monospacedDigit()

                        if let y = yesterday, y.totalCost > 0 {
                            let diff = today.totalCost - y.totalCost
                            let sign = diff >= 0 ? "+" : "-"
                            Text(String(format: L("ccusage.today.vsYesterday"),
                                        CCFormat.cost(y.totalCost),
                                        "\(sign)\(CCFormat.cost(abs(diff)))"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Spacer()

                    // Today Total Tokens
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(L("ccusage.today.tokens"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(CCFormat.compactTokens(today.totalTokens))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                        Text(CCFormat.fullTokens(today.totalTokens))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Divider().opacity(0.6)

                // Token Type Composition Pill Strip for Today
                HStack(spacing: 12) {
                    tokenMetricPill(
                        title: L("ccusage.metric.input"),
                        tokens: today.inputTokens,
                        color: .blue,
                        icon: "arrow.down.circle.fill"
                    )
                    tokenMetricPill(
                        title: L("ccusage.metric.output"),
                        tokens: today.outputTokens,
                        color: .green,
                        icon: "arrow.up.circle.fill"
                    )
                    tokenMetricPill(
                        title: L("ccusage.metric.cacheCreate"),
                        tokens: today.cacheCreationTokens,
                        color: .purple,
                        icon: "plus.square.fill.on.square.fill"
                    )
                    tokenMetricPill(
                        title: L("ccusage.metric.cacheRead"),
                        tokens: today.cacheReadTokens,
                        color: .teal,
                        icon: "bolt.horizontal.circle.fill"
                    )
                }

                Divider().opacity(0.6)

                // All-Time Totals Footer Row
                HStack {
                    Image(systemName: "sum")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(String(format: L("ccusage.totals.summary"),
                                store.report.daily.count,
                                CCFormat.cost(totals.totalCost),
                                CCFormat.compactTokens(totals.totalTokens)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(L("ccusage.section.today"))
        }
    }

    private func tokenMetricPill(title: String, tokens: Int64, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(CCFormat.compactTokens(tokens))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    // MARK: - 3. Recent Days Cost Trend Bar Chart

    private var trendChartSection: some View {
        let days = store.report.recentDays(count: prefs.trendRange.days)
        let maxCost = max(days.map(\.totalCost).max() ?? 1.0, 0.01)
        let focusedPeriod = store.focusedEntry.period

        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("ccusage.trend.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $prefs.trendRange) {
                        ForEach(CCTrendRange.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                // Interactive Bar Chart
                HStack(alignment: .bottom, spacing: prefs.trendRange == .days30 ? 3 : 6) {
                    ForEach(days) { day in
                        let isSelected = day.period == focusedPeriod
                        let ratio = max(0, min(1, day.totalCost / maxCost))
                        VStack(spacing: 4) {
                            if prefs.trendRange != .days30 && day.totalCost > 0 {
                                Text(day.totalCost >= 10 ? String(format: "$%.0f", day.totalCost) : String(format: "$%.1f", day.totalCost))
                                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                                    .foregroundStyle(isSelected ? .orange : .secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            } else {
                                Spacer(minLength: 0)
                            }

                            GeometryReader { geo in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(
                                            isSelected
                                            ? LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom)
                                            : LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                                        )
                                        .frame(height: day.totalCost > 0 ? max(4, CGFloat(ratio) * geo.size.height) : 2)
                                        .opacity(day.totalCost > 0 ? 1.0 : 0.25)
                                }
                            }
                            .frame(height: 88)

                            if shouldShowDateLabel(day: day, in: days) {
                                Text(day.shortDateLabel)
                                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            } else {
                                Text(" ")
                                    .font(.system(size: 9))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedPeriod = day.period
                        }
                        .help("\(day.period): \(CCFormat.cost(day.totalCost)) · \(CCFormat.compactTokens(day.totalTokens)) tokens")
                    }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } header: {
            Text(L("ccusage.section.trend"))
        }
    }

    private func shouldShowDateLabel(day: CCDailyEntry, in days: [CCDailyEntry]) -> Bool {
        guard prefs.trendRange == .days30 else { return true }
        guard let idx = days.firstIndex(where: { $0.period == day.period }) else { return true }
        return idx == days.count - 1 || idx % 3 == 0
    }

    // MARK: - 4. Agent & Model Breakdown for the Focused Day

    private var focusedBreakdownSection: some View {
        let entry = store.focusedEntry
        let agents = entry.sortedAgents
        let models = entry.sortedModels
        let maxAgentCost = max(agents.map(\.totalCost).max() ?? 1.0, 0.0001)
        let maxModelCost = max(models.map(\.cost).max() ?? 1.0, 0.0001)

        return Section {
            if agents.isEmpty && models.isEmpty {
                Text(L("ccusage.breakdown.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Agents sub-list
                if !agents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("ccusage.breakdown.agents"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(agents) { ag in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(agentColor(ag.agent))
                                        .frame(width: 8, height: 8)
                                    Text(ag.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                    if let used = ag.modelsUsed, !used.isEmpty {
                                        Text(used.joined(separator: ", "))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(CCFormat.compactTokens(ag.totalTokens))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    Text(CCFormat.cost(ag.totalCost))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                        .frame(minWidth: 58, alignment: .trailing)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.08))
                                        Capsule()
                                            .fill(agentColor(ag.agent))
                                            .frame(width: max(4, CGFloat(ag.totalCost / maxAgentCost) * geo.size.width))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Models sub-list
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("ccusage.breakdown.models"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(models) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(m.modelName)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    if m.missingPricing == true {
                                        Text(L("ccusage.model.unpriced"))
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.gray.opacity(0.2)))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("In \(CCFormat.compactTokens(m.inputTokens)) · Out \(CCFormat.compactTokens(m.outputTokens)) · Cache \(CCFormat.compactTokens(m.cacheCreationTokens + m.cacheReadTokens))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                    Text(CCFormat.cost(m.cost))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                        .frame(minWidth: 58, alignment: .trailing)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.08))
                                        Capsule()
                                            .fill(Color.indigo.opacity(0.8))
                                            .frame(width: max(3, CGFloat(m.cost / maxModelCost) * geo.size.width))
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text(String(format: L("ccusage.section.breakdown"), entry.period))
                Spacer()
                if store.selectedPeriod != nil && store.selectedPeriod != store.todayEntry.period {
                    Button(L("ccusage.action.backToToday")) {
                        store.selectedPeriod = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - 5. Expandable Daily History Table

    private var dailyHistorySection: some View {
        let rows = store.report.dailyNewestFirst

        return Section {
            ForEach(rows) { day in
                let isExpanded = store.expandedPeriods.contains(day.period)
                VStack(alignment: .leading, spacing: 8) {
                    // Summary header row
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Text(day.period)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))

                        // Agent badges
                        HStack(spacing: 4) {
                            ForEach(day.sortedAgents) { ag in
                                Text(ag.displayName)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(agentColor(ag.agent).opacity(0.16)))
                                    .foregroundStyle(agentColor(ag.agent))
                            }
                        }

                        Spacer()

                        Text(CCFormat.compactTokens(day.totalTokens))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Text(CCFormat.cost(day.totalCost))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isExpanded {
                            store.expandedPeriods.remove(day.period)
                        } else {
                            store.expandedPeriods.insert(day.period)
                        }
                        store.selectedPeriod = day.period
                    }

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            Divider().opacity(0.5)
                            HStack(spacing: 16) {
                                Label("In: \(CCFormat.compactTokens(day.inputTokens))", systemImage: "arrow.down")
                                Label("Out: \(CCFormat.compactTokens(day.outputTokens))", systemImage: "arrow.up")
                                Label("Cache Create: \(CCFormat.compactTokens(day.cacheCreationTokens))", systemImage: "plus.square.on.square")
                                Label("Cache Read: \(CCFormat.compactTokens(day.cacheReadTokens))", systemImage: "bolt.horizontal")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                            ForEach(day.sortedModels) { m in
                                HStack {
                                    Text("• \(m.modelName)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(CCFormat.compactTokens(m.totalTokens)) tok")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                    Text(CCFormat.cost(m.cost))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(minWidth: 56, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.leading, 22)
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(String(format: L("ccusage.section.history"), rows.count))
        }
    }

    // MARK: - 6. Bottom Version & Check Update Footer

    private var versionFooterSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let ver = store.ccusageVersion {
                    Text(String(format: L("ccusage.footer.version"), ver))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("ccusage.footer.versionUnknown"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let msg = store.updateStatusMessage {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if store.isCheckingUpdate || store.isAutoUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }

                Button {
                    store.checkAndUpdateCCUsage()
                } label: {
                    Label(L("ccusage.footer.checkUpdate"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isCheckingUpdate || store.isDownloadingBinary || store.isAutoUpdating)
            }
        }
    }

    // MARK: - Helpers

    private func agentColor(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude":      return .orange
        case "codex":       return .green
        case "antigravity": return .blue
        case "grok":        return .purple
        case "cursor":      return .teal
        default:            return .pink
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Window Accessor

private struct CCWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WindowTrackingView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
