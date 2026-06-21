import Foundation

/// A parsed LaunchAgent / LaunchDaemon plist entry from one of the three
/// well-known directories. The Launch Manager reads these directly (the plists
/// are world-readable) rather than relying on `launchctl`, so the inventory
/// works even for root daemons we can't otherwise inspect.
struct LaunchItem: Identifiable, Hashable {

    enum Domain: String, CaseIterable {
        case userAgent      // ~/Library/LaunchAgents   — runs as user, plist owned by user
        case systemAgent    // /Library/LaunchAgents     — runs as user, plist owned by root
        case systemDaemon   // /Library/LaunchDaemons    — runs as root, plist owned by root

        var directory: String {
            switch self {
            case .userAgent:    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
            case .systemAgent:  return "/Library/LaunchAgents"
            case .systemDaemon: return "/Library/LaunchDaemons"
            }
        }

        /// `launchctl` domain target prefix for this item's label.
        /// (gui/<uid> for agents; system for daemons.)
        func launchctlTarget(label: String, uid: uid_t) -> String {
            switch self {
            case .userAgent, .systemAgent: return "gui/\(uid)/\(label)"
            case .systemDaemon:            return "system/\(label)"
            }
        }
    }

    var id: String { plistPath }

    let label: String
    let plistPath: String
    let domain: Domain

    /// First entry of ProgramArguments, or the Program key.
    let programPath: String?
    let runAtLoad: Bool
    let keepAlive: Bool

    /// Whether `programPath` still exists on disk.
    let programExists: Bool

    /// Points to a binary that no longer exists → a leftover from an uninstalled app.
    var isOrphan: Bool { programPath != nil && !programExists }

    /// Modifying the plist (disable / move aside) needs root for /Library entries.
    var plistRequiresRoot: Bool { domain != .userAgent }

    /// The process this item launches runs as root (only true system daemons).
    var processRunsAsRoot: Bool { domain == .systemDaemon }
}
