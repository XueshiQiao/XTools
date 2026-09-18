import SwiftUI

/// Everything attached to this Mac, laid out the way it is actually connected.
///
/// The tree is rendered fully expanded rather than with collapsible rows: the
/// whole point is to see the chain from the Mac to a device at a glance, and a
/// real machine is only a handful of levels deep.
struct DeviceTreeView: View {

    @ObservedObject private var store: DeviceTreeStore

    init(store: DeviceTreeStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            hostSection
            ForEach(store.roots) { section in
                Section {
                    if section.children.isEmpty {
                        Text(L("devtree.notDetected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(flatten(section.children, depth: 0), id: \.node.id) { entry in
                            row(entry.node, depth: entry.depth)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(section.name)
                        Spacer(minLength: 8)
                        if let detail = section.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.devicetree.title"))
        .toolbar {
            ToolbarItem {
                Button { store.copyAsText() } label: {
                    Label(store.didCopy ? L("devtree.copied") : L("devtree.copy"),
                          systemImage: store.didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(store.roots.isEmpty)
            }
            ToolbarItem {
                Button { store.scan() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { if store.roots.isEmpty { store.scan() } }
    }

    // MARK: - Sections

    private var hostSection: some View {
        Section {
            LabeledContent {
                Text(store.hostSummary).font(.system(size: 11, design: .monospaced))
            } label: {
                iconLabel("laptopcomputer", .gray, L("devtree.thisMac"))
            }
            Toggle(isOn: $store.autoRefresh) {
                featureLabel("bolt.horizontal.circle.fill", .green,
                             L("devtree.auto.title"), L("devtree.auto.subtitle"))
            }
            if let lastScan = store.lastScan {
                LabeledContent {
                    Text(lastScan, style: .time).font(.caption).foregroundStyle(.secondary)
                } label: {
                    Text(store.isScanning ? L("devtree.scanning") : L("devtree.lastScan"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Rows

    private func row(_ node: DeviceNode, depth: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Indentation stands in for the tree lines; a leading rule keeps deep
            // rows visually tied to their parent.
            if depth > 0 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
                    .padding(.leading, CGFloat(depth - 1) * 16 + 12)
                    .padding(.vertical, 1)
            }
            IconTile(symbol: node.category.symbol, color: node.category.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).fontWeight(depth == 0 ? .medium : .regular)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(node.badges, id: \.self) { badge($0) }
                }
                if let detail = node.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .help(node.properties.map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .foregroundStyle(Color.accentColor)
    }

    // MARK: - Flattening

    private struct Entry {
        let node: DeviceNode
        let depth: Int
    }

    private func flatten(_ nodes: [DeviceNode], depth: Int) -> [Entry] {
        nodes.flatMap { node in
            [Entry(node: node, depth: depth)] + flatten(node.children, depth: depth + 1)
        }
    }
}
