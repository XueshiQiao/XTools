import SwiftUI
import AppKit

/// The Ports & Connections page: listening ports first ("who's on :3000"), then
/// active connections — searchable, with a one-tap kill on the owning process.
struct PortsView: View {

    @ObservedObject private var store: PortsStore
    @State private var pendingKill: Connection?

    private let autoRefresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(store: PortsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        // List (not Form): on macOS it's NSTableView-backed, so rows are
        // virtualized + reused — only visible rows render. A Form renders every
        // row eagerly, which is what made a large connection list lag.
        List {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            statusSection
            listenersSection
            connectionsSection
        }
        .listStyle(.inset)
        .navigationTitle(L("tool.ports.title"))
        .searchable(text: $store.query, prompt: Text(L("ports.search.prompt")))
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
            L("ports.kill.confirm.title"),
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { conn in
            Button(L("ports.kill.confirm.action"), role: .destructive) {
                store.kill(conn); pendingKill = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingKill = nil }
        } message: { conn in
            Text(String(format: L("ports.kill.confirm.message"), conn.command, conn.localDisplay))
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                Text(String(format: L("ports.status.count"), store.listeners.count, store.active.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } label: {
                iconLabel("network", .blue, L("ports.status.title"))
            }
            if store.connections.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("ports.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var listenersSection: some View {
        if !store.listeners.isEmpty {
            Section {
                ForEach(store.listeners) { connectionRow($0) }
            } header: {
                Text(L("ports.listeners.header"))
            } footer: {
                Text(L("ports.listeners.footer")).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var connectionsSection: some View {
        if !store.active.isEmpty {
            Section {
                ForEach(store.active) { connectionRow($0) }
            } header: {
                Text(L("ports.connections.header"))
            }
        }
    }

    // MARK: - Row

    private func connectionRow(_ conn: Connection) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: store.icon(for: conn))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conn.command).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(String(format: L("ports.pidLabel"), conn.pid))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    protoBadge(conn)
                    if let state = conn.state { stateBadge(state) }
                    if let svc = serviceName(conn) { badge(svc, .purple) }
                    if conn.dupCount > 1 { badge("×\(conn.dupCount)", .gray) }
                    if conn.runsAsRoot {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(conn.localDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if !conn.isListening {
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(conn.remoteDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        // If the destination is a local listening process, show it
                        // in parentheses (it's the OWNER of the remote endpoint,
                        // not a further hop A→B→C).
                        if let peer = conn.peerCommand, let ppid = conn.peerPid {
                            Text("(").font(.system(size: 11)).foregroundStyle(.tertiary)
                            Image(nsImage: store.icon(pid: ppid, path: conn.peerExecutablePath))
                                .resizable().frame(width: 14, height: 14)
                            Text("\(peer))").font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { pendingKill = conn } label: {
                Label(L("ports.kill"), systemImage: "stop.circle")
            }
            .controlSize(.small)
            .disabled(!conn.canKill)
            .help(conn.isCurrentUser ? L("ports.kill") : L("ports.root.hint"))
        }
        .padding(.vertical, 2)
    }

    /// Service label for the row's meaningful port: the listening port for a
    /// listener, the destination port for a connection.
    private func serviceName(_ conn: Connection) -> String? {
        let port = conn.isListening ? conn.localPort : (conn.remotePort ?? conn.localPort)
        return PortServices.name(for: port)
    }

    private func protoBadge(_ conn: Connection) -> some View {
        badge(conn.isIPv6 ? "\(conn.proto)6" : conn.proto, conn.proto == "TCP" ? .blue : .teal)
    }

    private func stateBadge(_ state: String) -> some View {
        badge(state, state == "LISTEN" ? .green : .gray)
    }

    // MARK: - Pieces

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
