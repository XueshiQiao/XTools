import SwiftUI

/// The Memory page: the headline memory-pressure signal + free % + total RAM, a
/// current breakdown (Free / Active / Inactive / Wired / Compressed / Purgeable
/// / Swap) with plain-language explanations, and a collapsed disclosure of the
/// scary since-boot cumulative counters.
struct MemoryView: View {

    @ObservedObject private var store: MemoryStore
    @State private var countersExpanded = false
    @State private var rawExpanded = false

    // @State so the publisher persists across SwiftUI's value-type view rebuilds
    // (a plain stored property would reset the 5s interval on every redraw).
    @State private var autoRefresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(store: MemoryStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var snap: MemorySnapshot { store.snapshot }

    var body: some View {
        Form {
            headlineSection
            compositionSection
            swapSection
            breakdownSection
            countersSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.memory.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in store.refresh() }
    }

    // MARK: - Headline

    private var headlineSection: some View {
        Section {
            // Memory pressure (colored traffic light + Normal/Warning/Critical).
            LabeledContent {
                Text(snap.pressure.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(snap.pressure.color)
            } label: {
                featureLabel("gauge.with.dots.needle.50percent", snap.pressure.color,
                             L("mem.pressure.title"), L("mem.pressure.sub"))
            }

            // System-wide free percentage.
            if let pct = snap.freePercent {
                LabeledContent {
                    Text("\(pct)%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } label: {
                    featureLabel("chart.pie.fill", .teal,
                                 L("mem.free.title"), L("mem.free.sub"))
                }
            }

            // Total RAM.
            LabeledContent {
                Text(byteText(snap.totalRAM)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            } label: {
                iconLabel("memorychip.fill", .pink, L("mem.total.title"))
            }
        } header: {
            Text(L("mem.section.headline"))
        }
    }

    // MARK: - Memory composition (stacked bar + legend)

    @ViewBuilder
    private var compositionSection: some View {
        if snap.hasComposition {
            Section {
                // The stacked bar.
                CompositionBar(categories: snap.categories, total: snap.totalRAM)
                    .frame(height: 46)
                    .padding(.vertical, 4)

                // Legend: one row per category (swatch + label + size + percent).
                ForEach(snap.categories.filter { $0.bytes > 0 }) { cat in
                    legendRow(cat)
                }
            } header: {
                Text(L("mem.composition.header"))
            } footer: {
                Text(L("mem.composition.footer")).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One legend row: color swatch + localized label, then size + percent
    /// trailing. The Compressed row also carries the "physical holds logical"
    /// savings line when the compressor is doing real work.
    private func legendRow(_ cat: MemoryCategory) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(byteText(cat.bytes)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text("\(percent(cat.bytes))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(cat.color)
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(cat.labelKey))
                    if cat.id == "compressed", snap.hasCompressionSavings {
                        Text(String(format: L("mem.compressed.savings"),
                                    byteText(snap.compressedPhysical),
                                    byteText(snap.compressedLogical),
                                    byteText(snap.compressedLogical - snap.compressedPhysical)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Swap (its own section — swap lives on disk, not in RAM)

    private var swapSection: some View {
        Section {
            // A small orange used/total bar.
            SwapBar(used: snap.swapUsed, total: snap.swapTotal)
                .frame(height: 10)
                .padding(.vertical, 2)
            LabeledContent {
                Text(String(format: L("mem.swap.usedOf"),
                            byteText(snap.swapUsed), byteText(snap.swapTotal)))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            } label: {
                iconLabel("externaldrive.fill", .orange, L("mem.row.swap"))
            }
        } header: {
            Text(L("mem.swap.header"))
        } footer: {
            Text(L("mem.row.swap.sub")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Raw page counts (collapsed)

    private var breakdownSection: some View {
        Section {
            DisclosureGroup(isExpanded: $rawExpanded) {
                if snap.isValid {
                    ForEach(snap.rows) { row in
                        breakdownRow(symbol: row.symbol, color: row.color,
                                     title: row.label, subtitle: row.subtitle,
                                     value: byteText(row.bytes))
                    }
                } else {
                    Text(store.isScanning ? L("launch.scanning") : L("mem.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Text(L("mem.raw.header")).fontWeight(.medium)
            }
        }
    }

    /// A breakdown row: icon tile + title over a wrapping plain-language subtitle,
    /// with the formatted byte value trailing.
    private func breakdownRow(symbol: String, color: Color,
                              title: String, subtitle: String, value: String) -> some View {
        LabeledContent {
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        } label: {
            featureLabel(symbol, color, title, subtitle)
        }
    }

    /// Percentage of total RAM (rounded, clamped 0…100) for the legend.
    private func percent(_ bytes: UInt64) -> Int {
        guard snap.totalRAM > 0 else { return 0 }
        return min(100, Int((Double(bytes) / Double(snap.totalRAM) * 100).rounded()))
    }

    // MARK: - Cumulative counters (collapsed)

    private var countersSection: some View {
        Section {
            DisclosureGroup(isExpanded: $countersExpanded) {
                ForEach(snap.counters) { counter in
                    LabeledContent {
                        Text(countText(counter.count)).foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    } label: {
                        Text(counter.label)
                    }
                }
            } label: {
                Text(L("mem.counters.title")).fontWeight(.medium)
            }
        } footer: {
            Text(L("mem.counters.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory          // 1024-based, matches Activity Monitor.
        f.allowedUnits = [.useGB, .useMB, .useKB]
        return f
    }()

    private func byteText(_ bytes: UInt64) -> String {
        // Memory byte counts never approach Int64.max, so a plain clamp is safe.
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal        // grouping separators for the big numbers.
        return f
    }()

    private func countText(_ count: UInt64) -> String {
        countFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Stacked composition bar

/// A rounded horizontal bar partitioning total RAM: one segment per category,
/// width ∝ bytes/total. Sub-pixel slices are dropped so they don't smear the
/// rounded corners. Uses GeometryReader so the segments track the live width.
private struct CompositionBar: View {
    let categories: [MemoryCategory]
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Normalize against the LARGER of total and the slice sum: the two
            // subprocesses are sampled a few ms apart, so the categories can sum
            // to slightly more than total RAM. Dividing by that larger denominator
            // keeps the segments inside `width` instead of clipping the last slice.
            let denom = max(total, sliceSum)
            HStack(spacing: 0) {
                ForEach(categories) { cat in
                    let segWidth = segmentWidth(cat.bytes, full: width, denom: denom)
                    if segWidth > 0.5 {
                        Rectangle()
                            .fill(cat.color)
                            .frame(width: segWidth)
                    }
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
    }

    private var sliceSum: UInt64 { categories.reduce(0) { $0 &+ $1.bytes } }

    private func segmentWidth(_ bytes: UInt64, full: CGFloat, denom: UInt64) -> CGFloat {
        guard denom > 0 else { return 0 }
        return full * CGFloat(Double(bytes) / Double(denom))
    }
}

// MARK: - Swap usage bar

/// A small orange used/total bar for swap. Distinct from the RAM bar: swap lives
/// on disk, so it's its own track on a gray rail.
private struct SwapBar: View {
    let used: UInt64
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.18))
                Capsule()
                    .fill(Color.orange)
                    .frame(width: fillWidth(full: width))
            }
        }
    }

    private func fillWidth(full: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return full * CGFloat(min(1, Double(used) / Double(total)))
    }
}
