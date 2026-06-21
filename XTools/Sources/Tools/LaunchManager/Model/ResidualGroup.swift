import Foundation

/// A cluster of background processes that all live inside one `.app` bundle whose
/// main app is NOT currently running — the "ghost process" case (e.g. Baidu
/// Netdisk's `netdisk_service` still running after you quit the app).
///
/// Detection is purely informational: the user decides whether to reap a group
/// or create a Guardian rule for it. `classification` lets the UI avoid alarming
/// the user about legitimate background updaters.
struct ResidualGroup: Identifiable {

    enum Classification {
        case offender     // known to leave junk behind (e.g. Baidu) — suggest reaping
        case benign       // known legitimate 3rd-party background service/updater
        case appleSystem  // Apple's own system service/widget — collapsed away by default
        case unknown      // found, no opinion — the user decides
    }

    let appBundlePath: String
    let appName: String
    let appBundleID: String?
    let helpers: [ManagedProcess]
    let classification: Classification

    var id: String { appBundlePath }

    /// Any helper runs as root → reaping needs the privileged (password) path.
    var containsRoot: Bool { helpers.contains { $0.runsAsRoot } }

    var helperCount: Int { helpers.count }
}
