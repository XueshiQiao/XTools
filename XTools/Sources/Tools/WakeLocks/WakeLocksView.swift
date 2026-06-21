import SwiftUI
import AppKit

/// The Wake Locks page: which processes are currently preventing the display /
/// system from sleeping, why, for how long — with a one-tap "end process".
struct WakeLocksView: View {

    @ObservedObject private var store: WakeLocksStore
    @State private var pendingRelease: AssertionHolder?

    private let autoRefresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(store: WakeLocksStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var displayBlockers: [AssertionHolder] { store.holders.filter { $0.preventsDisplaySleep } }
    private var systemOnlyBlockers: [AssertionHolder] {
        store.holders.filter { $0.preventsSystemSleep && !$0.preventsDisplaySleep }
    }

    var body: some View {
        Form {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            statusSection
            if !displayBlockers.isEmpty {
                Section {
                    ForEach(displayBlockers) { holderRow($0) }
                } header: {
                    Text(L("wake.display.header"))
                } footer: {
                    Text(L("wake.footer")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !systemOnlyBlockers.isEmpty {
                Section {
                    ForEach(systemOnlyBlockers) { holderRow($0) }
                } header: {
                    Text(L("wake.system.header"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.wake.title"))
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
        .confirmationDialog(
            L("wake.end.confirm.title"),
            isPresented: Binding(get: { pendingRelease != nil }, set: { if !$0 { pendingRelease = nil } }),
            presenting: pendingRelease
        ) { holder in
            Button(L("wake.end.confirm.action"), role: .destructive) {
                store.release(holder); pendingRelease = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingRelease = nil }
        } message: { holder in
            Text(String(format: L("wake.end.confirm.message"), holder.processName))
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                Text(displayBlockers.isEmpty
                     ? L("wake.status.none")
                     : String(format: L("wake.status.count"), displayBlockers.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(displayBlockers.isEmpty ? .green : .orange)
            } label: {
                iconLabel("cup.and.saucer.fill", displayBlockers.isEmpty ? .green : .orange,
                          L("wake.status.title"))
            }
            if displayBlockers.isEmpty && systemOnlyBlockers.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("wake.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Row

    private func holderRow(_ holder: AssertionHolder) -> some View {
        HStack(spacing: 10) {
            icon(for: holder)
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(holder.processName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if holder.preventsDisplaySleep { badge(L("wake.badge.display"), .orange) }
                    if holder.preventsSystemSleep { badge(L("wake.badge.system"), .purple) }
                    if holder.runsAsRoot {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(holder.reasons.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if let since = holder.since {
                    Text(String(format: L("wake.heldFor"), durationString(since: since)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { pendingRelease = holder } label: {
                Label(L("wake.end"), systemImage: "stop.circle")
            }
            .controlSize(.small)
            .disabled(!holder.canEnd)
            .help(holder.canEnd ? L("wake.end") : L("wake.root.hint"))
        }
        .padding(.vertical, 2)
    }

    private func icon(for holder: AssertionHolder) -> Image {
        if let app = NSRunningApplication(processIdentifier: holder.pid), let ic = app.icon {
            return Image(nsImage: ic)
        }
        if let p = holder.executablePath {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: p))
        }
        return Image(systemName: "bolt.fill")
    }

    // MARK: - Pieces

    private func durationString(since: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(since)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.actionMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
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
