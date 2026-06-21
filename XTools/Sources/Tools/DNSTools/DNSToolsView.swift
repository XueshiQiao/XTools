import SwiftUI

/// The DNS & hosts page: current DNS resolvers + search domains, a "flush DNS
/// cache" button, and an `/etc/hosts` viewer + editor. The two privileged actions
/// (flush, save) confirm first and surface a result banner.
struct DNSToolsView: View {

    @ObservedObject private var store: DNSToolsStore
    @State private var confirmingFlush = false
    @State private var confirmingSave = false

    init(store: DNSToolsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            resolversSection
            flushSection
            hostsSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.dns.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { store.refresh() }
        .confirmationDialog(
            L("dns.flush.confirm.title"),
            isPresented: $confirmingFlush
        ) {
            Button(L("dns.flush.confirm.action")) { store.flushCache() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("dns.flush.confirm.message"))
        }
        .confirmationDialog(
            L("dns.hosts.save.confirm.title"),
            isPresented: $confirmingSave
        ) {
            Button(L("dns.hosts.save.confirm.action")) { store.saveHosts() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("dns.hosts.save.confirm.message"))
        }
    }

    // MARK: - Resolvers

    private var resolversSection: some View {
        Section {
            if store.dns.resolverAddresses.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("dns.resolvers.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.dns.resolverAddresses, id: \.self) { addr in
                    LabeledContent {
                        Text(addr)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } label: {
                        iconLabel("server.rack", .teal, L("dns.resolvers.nameserver"))
                    }
                }
            }
            if !store.dns.searchDomains.isEmpty {
                LabeledContent {
                    Text(store.dns.searchDomains.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } label: {
                    iconLabel("magnifyingglass", .blue, L("dns.resolvers.search"))
                }
            }
        } header: {
            Text(L("dns.section.resolvers"))
        } footer: {
            Text(L("dns.resolvers.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Flush

    private var flushSection: some View {
        Section {
            HStack {
                iconLabel("arrow.triangle.2.circlepath", .orange, L("dns.flush.title"))
                Spacer()
                Button {
                    confirmingFlush = true
                } label: {
                    if store.isFlushing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("dns.flush.button"))
                    }
                }
                .disabled(store.isFlushing)
            }
        } header: {
            Text(L("dns.section.flush"))
        } footer: {
            Text(L("dns.flush.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Hosts

    private var hostsSection: some View {
        Section {
            if store.hostEntries.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("dns.hosts.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.hostEntries) { entry in
                    hostRow(entry)
                }
            }

            // Editor.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("dns.hosts.editor.label"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.hostsDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                HStack {
                    Button(L("dns.hosts.revert")) { store.revertHosts() }
                        .disabled(!store.hostsDirty || store.isSaving)
                    Spacer()
                    Button {
                        confirmingSave = true
                    } label: {
                        if store.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("dns.hosts.save"))
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.hostsDirty || store.isSaving)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text(L("dns.hosts.header"))
        } footer: {
            Text(L("dns.hosts.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hostRow(_ entry: HostEntry) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: "number", color: .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.ip)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                Text(entry.hostnames.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Banner

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.actionMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}
