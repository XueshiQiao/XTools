import SwiftUI
import AppKit
import Combine

/// UI model for the Default Apps tool.
///
/// The scan (reading current + candidate handlers, resolving app names/icons)
/// runs off the main thread and publishes on main. Changing a default also runs
/// off main (LaunchServices does disk work) and re-reads ONLY the affected item
/// afterward so the row reflects the new handler without a full rescan.
final class DefaultAppsStore: ObservableObject {

    @Published private(set) var fileTypes: [HandledItem] = []
    @Published private(set) var urlSchemes: [HandledItem] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    private let work = DispatchQueue(label: "me.xueshi.xtools.defaultapps", qos: .userInitiated)

    // MARK: - Scan

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let types = HandlerScanner.scanFileTypes()
            let schemes = HandlerScanner.scanURLSchemes()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileTypes = types
                self.urlSchemes = schemes
                self.isScanning = false
            }
        }
    }

    // MARK: - Change a default

    /// Set `app` as the default handler for `item`, then re-read just that item so
    /// its row updates in place. User-domain change — no admin password needed.
    func setHandler(_ app: HandlerApp, for item: HandledItem) {
        // No-op if it's already the handler.
        guard app.bundleID != item.current?.bundleID else { return }

        work.async { [weak self] in
            let status: OSStatus
            switch item.kind {
            case .contentType:
                status = LaunchServicesBridge.setDefaultHandler(forContentType: item.identifier, bundleID: app.bundleID)
            case .urlScheme:
                status = LaunchServicesBridge.setDefaultHandler(forURLScheme: item.identifier, bundleID: app.bundleID)
            }
            Analytics.trackLaunchAction(kind: "default_handler_set", scope: "user")

            // Re-read the affected item so the row shows what the system actually
            // recorded (a failed set leaves the old handler — the source of truth).
            let refreshed = Self.rescan(item)

            DispatchQueue.main.async {
                guard let self else { return }
                self.replace(refreshed)
                let nowHandler = refreshed?.current?.name ?? app.name
                if status == noErr {
                    self.actionMessage = String(format: L("defaultapps.msg.set"), nowHandler, item.label)
                } else {
                    self.actionMessage = String(format: L("defaultapps.msg.failed"), item.label)
                }
            }
        }
    }

    func revealInFinder(_ app: HandlerApp) {
        guard let url = app.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Internals

    /// Re-resolve a single item from LaunchServices (off main; called from `work`).
    /// Scans only that one entry — not the whole catalog — to keep the post-change
    /// update cheap.
    private static func rescan(_ item: HandledItem) -> HandledItem? {
        guard let entry = HandledCatalog.entry(for: item) else { return nil }
        return HandlerScanner.scan(entry)
    }

    /// Replace one item in whichever published list owns it (main thread).
    private func replace(_ item: HandledItem?) {
        guard let item else { return }
        switch item.kind {
        case .contentType:
            if let idx = fileTypes.firstIndex(where: { $0.id == item.id }) { fileTypes[idx] = item }
        case .urlScheme:
            if let idx = urlSchemes.firstIndex(where: { $0.id == item.id }) { urlSchemes[idx] = item }
        }
    }
}
