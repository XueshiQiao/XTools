import Foundation

/// A user-created rule: "whenever the main app of `appBundlePath` is NOT running,
/// reap every process whose executable lives inside that bundle."
///
/// This is the user's preferred root-cause approach — instead of deleting the
/// LaunchAgent plist (which the vendor re-adds on next launch), we let the plist
/// be and simply reap the orphaned helpers whenever their owning app isn't up.
///
/// Rules are opt-in: detection never creates one automatically. The continuous
/// reaper enforces only user-level helpers; root helpers under a rule are
/// surfaced but require the on-demand (password-prompt) path, since a background
/// loop can't prompt for a password.
struct GuardianRule: Identifiable, Codable, Hashable {
    var id: UUID
    var appName: String
    var appBundlePath: String
    var appBundleID: String?
    var enabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(), appName: String, appBundlePath: String,
         appBundleID: String?, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.appName = appName
        self.appBundlePath = appBundlePath
        self.appBundleID = appBundleID
        self.enabled = enabled
        self.createdAt = createdAt
    }
}
