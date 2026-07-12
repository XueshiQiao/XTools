import SwiftUI
import AppKit

/// The Dashboard: a glanceable grid of summary cards aggregating the tools'
/// data. Each card is fully clickable and routes to its tool. Cards refresh on
/// appear and on a slow timer.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = DashboardStore()

    private let autoRefresh = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                MemoryCard(data: store.data)
                if store.data.battery.isPresent { BatteryCard(battery: store.data.battery) }
                WakeCard(count: store.data.wakeDisplayCount, holders: store.data.wakeDisplayList)
                NowPlayingCard(sources: store.data.audioSources)
                PortsCard(listening: store.data.portsListening, connections: store.data.portsConnections)
                DiskCard(free: store.data.diskFree, total: store.data.diskTotal)
                PlaceholderCard()
            }
            .padding(20)
        }
        .navigationTitle(L("dashboard.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in store.refresh() }
    }
}

// MARK: - Card chrome

/// Generic card shell: header (icon + title + chevron when it links somewhere),
/// then content. The WHOLE card hit-tests and routes to `destination` on tap;
/// hover tints the border with the system accent.
private struct CardShell<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var destination: SidebarItem? = nil
    @ViewBuilder var content: () -> Content

    @EnvironmentObject var appState: AppState
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.18)))
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                if destination != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hover && destination != nil ? 0.06 : 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(hover && destination != nil ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06))
                )
        )
        // Hit area matches the visible rounded card (no clickable dead zones at
        // the corners) — only nav cards capture taps.
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if let destination { appState.selection = destination } }
        .onHover { hover = $0 }
    }
}

// MARK: - Cards

private struct MemoryCard: View {
    let data: DashboardData
    private var swapFraction: Double {
        data.memory.swapTotal > 0 ? Double(data.memory.swapUsed) / Double(data.memory.swapTotal) : 0
    }
    var body: some View {
        CardShell(title: L("dashboard.card.memory"), symbol: "memorychip.fill", tint: .pink,
                  destination: .tool("memory")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    CompositionRing(categories: data.memory.categories,
                                    total: data.memory.totalRAM,
                                    center: data.memory.freePercent.map { "\($0)%" } ?? "—")
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 7) {
                        Pill(text: String(format: L("dashboard.pressure"), data.memory.pressure.label),
                             color: data.memory.pressure.color)
                        Text(String(format: L("dashboard.memory.used"),
                                    byteText(data.memoryUsed), byteText(data.memory.totalRAM)))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(L("dashboard.free.label")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                // Swap lives inside the memory card: it's disk-backed overflow
                // for RAM, strongly tied to memory pressure — not a standalone
                // concept, so it reads as a sub-section here.
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.cyan)
                        Text(L("dashboard.card.swap")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("\(byteText(data.memory.swapUsed)) / \(byteText(data.memory.swapTotal))")
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    MiniBar(fraction: swapFraction, color: .orange)
                    Text(L("dashboard.swap.sub")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryInfo

    private var isCharging: Bool { battery.power?.isCharging ?? false }
    private var chargeFraction: Double {
        battery.power?.chargePercent.map { Double($0) / 100 } ?? 0
    }
    private var healthFraction: Double {
        battery.maxCapacityPercent.map { Double($0) / 100 } ?? 0
    }
    private var chargeCenter: String { battery.power?.chargePercent.map { "\($0)%" } ?? "—" }
    private var healthCenter: String { battery.maxCapacityPercent.map { "\($0)%" } ?? "—" }

    /// Charge ring color: green while charging, otherwise driven by how much
    /// charge is left (green ≥ 50, yellow 20–49, red below).
    private var chargeColor: Color {
        if isCharging { return .green }
        guard let pct = battery.power?.chargePercent else { return .gray }
        switch pct {
        case 50...:   return .green
        case 20..<50: return .yellow
        default:      return .red
        }
    }

    /// Health ring color: orange when macOS flags service, otherwise driven by
    /// max-capacity health (green ≥ 80, yellow 60–79, red below).
    private var healthColor: Color {
        if battery.condition?.isHealthy == false { return .orange }
        guard let pct = battery.maxCapacityPercent else { return .gray }
        switch pct {
        case 80...:   return .green
        case 60..<80: return .yellow
        default:      return .red
        }
    }

    var body: some View {
        CardShell(title: L("dashboard.card.battery"), symbol: "battery.100", tint: .green,
                  destination: .tool("power-insights")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    ProgressRing(fraction: chargeFraction, color: chargeColor,
                                 center: chargeCenter, caption: L("dashboard.battery.chargeLabel"))
                        .frame(width: 84, height: 84)
                    ProgressRing(fraction: healthFraction, color: healthColor,
                                 center: healthCenter, caption: L("dashboard.battery.healthLabel"))
                        .frame(width: 84, height: 84)
                    Spacer(minLength: 0)
                }
                Text(isCharging ? L("dashboard.battery.charging") : L("dashboard.battery.onBattery"))
                    .font(.system(size: 12)).foregroundStyle(isCharging ? .green : .secondary)
            }
        }
    }
}

private struct WakeCard: View {
    let count: Int
    let holders: [WakeGlance]
    var body: some View {
        CardShell(title: L("dashboard.card.wake"), symbol: "cup.and.saucer.fill", tint: .orange,
                  destination: .tool("wake-locks")) {
            if holders.isEmpty {
                Metric(value: "\(count)", unit: "", color: .green)
                Text(L("dashboard.wake.none"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Mirror the Now Playing card: big count, then the top blockers as
                // icon + name + how long they've held the display awake.
                Metric(value: "\(count)", unit: L("dashboard.wake.unit"), color: .orange)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(holders.prefix(3)) { holder in
                        HStack(spacing: 8) {
                            Image(nsImage: holder.appIcon)
                                .resizable().frame(width: 18, height: 18)
                            Text(holder.processName)
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let held = holder.heldFor {
                                Text(AudioSource.durationText(held))
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                    }
                    if count > 3 {
                        Text(String(format: L("dashboard.wake.more"), count - 3))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct NowPlayingCard: View {
    let sources: [AudioSource]
    var body: some View {
        CardShell(title: L("dashboard.card.nowplaying"), symbol: "waveform", tint: .pink,
                  destination: .tool("now-playing")) {
            if sources.isEmpty {
                Metric(value: "0", unit: "", color: .green)
                Text(L("dashboard.nowplaying.none"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Metric(value: "\(sources.count)", unit: L("dashboard.nowplaying.unit"), color: .pink)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sources.prefix(3)) { source in
                        HStack(spacing: 8) {
                            Image(nsImage: source.appIcon)
                                .resizable().frame(width: 18, height: 18)
                            Text(source.processName)
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let held = source.heldFor {
                                Text(AudioSource.durationText(held))
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                    }
                    if sources.count > 3 {
                        Text(String(format: L("dashboard.nowplaying.more"), sources.count - 3))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct PortsCard: View {
    let listening: Int
    let connections: Int
    var body: some View {
        CardShell(title: L("dashboard.card.ports"), symbol: "network", tint: .blue,
                  destination: .tool("ports")) {
            Metric(value: "\(listening)", unit: L("dashboard.ports.unit"))
            Text(String(format: L("dashboard.ports.sub"), connections))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct DiskCard: View {
    let free: Int64
    let total: Int64
    private var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    var body: some View {
        CardShell(title: L("dashboard.card.disk"), symbol: "internaldrive.fill", tint: .purple) {
            Metric(value: byteText(free), unit: L("dashboard.disk.freeUnit"))
            MiniBar(fraction: usedFraction, color: .purple)
            Text(String(format: L("dashboard.disk.total"), byteText(total)))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text(L("dashboard.placeholder")).font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(Color.primary.opacity(0.12))
        )
    }
}

// MARK: - Pieces

/// A segmented ring (donut) of memory categories, with a centered label.
private struct CompositionRing: View {
    let categories: [MemoryCategory]
    let total: UInt64
    let center: String

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let lw: CGFloat = 11
                let r = (min(size.width, size.height) - lw) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                // Normalize against the actual sum of slices, not total RAM: the
                // partition usually equals total (Other balances it), but a
                // non-atomic read can overshoot — dividing by the sum keeps the
                // ring exactly full with no overlap, and shows a gray placeholder
                // when there's nothing to draw.
                let active = categories.filter { $0.bytes > 0 }
                let sum = active.reduce(UInt64(0)) { $0 + $1.bytes }
                guard sum > 0 else {
                    var ring = Path()
                    ring.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    ctx.stroke(ring, with: .color(.gray.opacity(0.3)), style: StrokeStyle(lineWidth: lw))
                    return
                }
                var start = -90.0
                for cat in active {
                    let sweep = Double(cat.bytes) / Double(sum) * 360
                    var arc = Path()
                    arc.addArc(center: c, radius: r,
                               startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
                    ctx.stroke(arc, with: .color(cat.color), style: StrokeStyle(lineWidth: lw, lineCap: .butt))
                    start += sweep
                }
            }
            VStack(spacing: 0) {
                Text(center).font(.system(size: 18, weight: .semibold))
                Text(L("dashboard.free.short")).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A single-arc progress ring (0…1) with a centered big-number + caption label.
/// Matches `CompositionRing`'s 84×84 sizing and stroke weight so every Dashboard
/// ring reads as one family; a round cap keeps the progress arc's tip clean.
private struct ProgressRing: View {
    let fraction: Double
    let color: Color
    let center: String
    let caption: String

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let lw: CGFloat = 11
                let r = (min(size.width, size.height) - lw) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                // Full background track (same gray as CompositionRing's empty state).
                var track = Path()
                track.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                ctx.stroke(track, with: .color(.gray.opacity(0.3)), style: StrokeStyle(lineWidth: lw))
                // Colored progress arc from 12 o'clock, clockwise.
                let sweep = max(0, min(1, fraction)) * 360
                guard sweep > 0 else { return }
                var arc = Path()
                arc.addArc(center: c, radius: r,
                           startAngle: .degrees(-90), endAngle: .degrees(-90 + sweep), clockwise: false)
                ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            VStack(spacing: 0) {
                Text(center).font(.system(size: 18, weight: .semibold))
                Text(caption).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Metric: View {
    let value: String
    var unit: String = ""
    var color: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: 30, weight: .semibold)).foregroundStyle(color)
            if !unit.isEmpty { Text(unit).font(.system(size: 14)).foregroundStyle(.secondary) }
        }
    }
}

private struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

private struct MiniBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 7)
    }
}

private func byteText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}
