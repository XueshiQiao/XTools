import SwiftUI
import Combine

/// UI model for the DNS & hosts tool.
///
/// Reads (scutil --dns and /etc/hosts) run off the main thread and publish on
/// main. The two privileged actions — flushing the DNS cache and saving
/// `/etc/hosts` — also run off main (they block on an admin password prompt) and
/// route through `PrivilegedRunner`. Results surface via `actionMessage`.
final class DNSToolsStore: ObservableObject {

    // Current DNS configuration.
    @Published private(set) var dns = DNSConfig()

    // /etc/hosts: parsed entries + the raw text (the editor's source of truth).
    @Published private(set) var hostEntries: [HostEntry] = []
    @Published var hostsDraft: String = ""
    @Published private(set) var hostsOriginal: String = ""

    @Published private(set) var isScanning = false
    @Published private(set) var isSaving = false
    @Published private(set) var isFlushing = false
    @Published var actionMessage: String?

    /// True when the editor has unsaved changes.
    var hostsDirty: Bool { hostsDraft != hostsOriginal }

    private let work = DispatchQueue(label: "me.xueshi.xtools.dnstools", qos: .userInitiated)

    // MARK: - Read

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let dns = DNSReader.read()
            let raw = HostsFile.readRaw() ?? ""
            let entries = HostsFile.parse(raw)
            DispatchQueue.main.async {
                guard let self else { return }
                // Capture dirtiness against the OLD original before we replace it,
                // so we only reset the editor draft when the user hasn't edited it
                // yet — a background refresh never discards in-progress edits.
                let wasDirty = self.hostsDirty
                self.dns = dns
                self.hostEntries = entries
                self.hostsOriginal = raw
                if !wasDirty || self.hostsDraft.isEmpty {
                    self.hostsDraft = raw
                }
                self.isScanning = false
            }
        }
    }

    /// Discard editor changes back to the on-disk contents.
    func revertHosts() {
        hostsDraft = hostsOriginal
    }

    // MARK: - Flush DNS cache (privileged)

    func flushCache() {
        guard !isFlushing else { return }
        isFlushing = true
        work.async { [weak self] in
            let result = DNSFlusher.flush()
            Analytics.trackLaunchAction(kind: "dns_flush", scope: "system")
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFlushing = false
                switch result {
                case .success:
                    self.actionMessage = L("dns.flush.success")
                case .failure(let error):
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Save /etc/hosts (privileged, backed up first)

    func saveHosts() {
        guard !isSaving else { return }
        let contents = hostsDraft
        isSaving = true
        work.async { [weak self] in
            let result = HostsFile.write(contents)
            Analytics.trackLaunchAction(kind: "hosts_save", scope: "system")
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success:
                    self.hostsOriginal = contents
                    self.hostEntries = HostsFile.parse(contents)
                    self.actionMessage = L("dns.hosts.save.success")
                case .failure(let error):
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }
}
