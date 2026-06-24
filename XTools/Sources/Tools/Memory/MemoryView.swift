import SwiftUI

/// The Memory page: the headline memory-pressure signal + free % + total RAM, a
/// current breakdown (Free / Active / Inactive / Wired / Compressed / Purgeable
/// / Swap) with plain-language explanations, and a collapsed disclosure of the
/// scary since-boot cumulative counters.
struct MemoryView: View {

    @ObservedObject private var store: MemoryStore
    @State private var countersExpanded = false

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

    // MARK: - Current breakdown

    private var breakdownSection: some View {
        Section {
            if snap.isValid {
                ForEach(snap.rows) { row in
                    breakdownRow(symbol: row.symbol, color: row.color,
                                 title: row.label, subtitle: row.subtitle,
                                 value: byteText(row.bytes))
                }
                // Swap used (X used of Y).
                breakdownRow(symbol: "externaldrive.fill", color: .red,
                             title: L("mem.row.swap"), subtitle: L("mem.row.swap.sub"),
                             value: String(format: L("mem.swap.usedOf"),
                                           byteText(snap.swapUsed), byteText(snap.swapTotal)))
            } else {
                Text(store.isScanning ? L("launch.scanning") : L("mem.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(L("mem.section.breakdown"))
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
