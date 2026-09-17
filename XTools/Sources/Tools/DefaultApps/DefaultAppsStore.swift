import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// UI model for the Default Apps tool.
///
/// The scan (reading current + candidate handlers, resolving app names/icons)
/// runs off the main thread and publishes on main. Changing a default re-reads
/// ONLY the affected item afterward, so the row reflects the new handler without
/// a full rescan.
final class DefaultAppsStore: ObservableObject {

    private static let log = FileLog("DefaultApps")

    @Published private(set) var fileTypes: [HandledItem] = []
    @Published private(set) var urlSchemes: [HandledItem] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    /// Rows with a change in flight. macOS's consent alert doesn't block our
    /// window, so without this the user could pick a second app for the same row
    /// while the first alert is still up — two overlapping requests whose order
    /// the system doesn't promise, and the EARLIER choice could be the one that
    /// sticks. The picker for a pending row is disabled until it settles.
    @Published private(set) var pending: Set<String> = []

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

    /// Set `app` as the default handler for `item`, then update that row once the
    /// system has actually recorded it. User-domain change — no admin password.
    ///
    /// Timing is the whole story here. For most types macOS asks the user to
    /// confirm ("Use <new app>?" / "Keep <old app>?"), and it asks
    /// **asynchronously**: the old `LSSetDefaultRoleHandler…` call returns `noErr`
    /// before that alert is even on screen, so re-reading right afterwards always
    /// saw the OLD handler — which is why the row used to look unchanged until you
    /// left the page and came back. `NSWorkspace.setDefaultApplication(at:toOpen:)`
    /// (macOS 12+, despite what the old comment in `LaunchServicesBridge` claimed)
    /// only returns once the user has answered that alert — so we await it and
    /// re-read the row afterwards.
    func setHandler(_ app: HandlerApp, for item: HandledItem) {
        // No-op if it's already the handler, or if this row is already waiting.
        guard app.bundleID != item.current?.bundleID, !pending.contains(item.id) else { return }

        // An app we couldn't locate on disk (a stale registration) can't be set.
        guard let appURL = app.url else {
            actionMessage = String(format: L("defaultapps.msg.failed"), item.label)
            Self.log.warn("can't set \(app.bundleID) for \(item.identifier): app not found on disk")
            return
        }

        // Everything that can fail up front is resolved BEFORE the async hop, so a
        // row we can't act on says so immediately instead of after a round trip.
        let apply: () async throws -> Void
        switch item.kind {
        case .contentType:
            guard let type = UTType(item.identifier) else {
                actionMessage = String(format: L("defaultapps.msg.failed"), item.label)
                Self.log.warn("unknown UTI \(item.identifier) — can't set a handler for it")
                return
            }
            apply = { try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) }
        case .urlScheme:
            apply = {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL,
                                                                   toOpenURLsWithScheme: item.identifier)
            }
        }

        pending.insert(item.id)

        Task { [weak self] in
            do {
                try await apply()
            } catch {
                // Includes the user answering "Keep" in the consent alert.
                Self.log.warn("setDefault \(item.identifier) → \(app.bundleID): \(error.localizedDescription)")
            }
            self?.reconcile(item, target: app)
        }

        Analytics.trackLaunchAction(kind: "default_handler_set", scope: "user")
    }

    /// Re-read the row after the system has settled and say what actually happened.
    ///
    /// Called once the `await` above has returned, on no particular queue — so it
    /// hops to `work` for the disk I/O and to main for the publish. Whatever the
    /// system recorded is what the row shows, including "the user said Keep", so
    /// this never reports a change that didn't happen. Two changes to different
    /// rows can't interfere: each call only ever touches its own `item`.
    private func reconcile(_ item: HandledItem, target: HandlerApp) {
        work.async { [weak self] in
            let refreshed = Self.rescan(item)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(item.id)
                self.replace(refreshed)
                if refreshed?.current?.bundleID == target.bundleID {
                    self.actionMessage = String(format: L("defaultapps.msg.set"),
                                                refreshed?.current?.name ?? target.name, item.label)
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
