import Foundation

/// A small, conservative reference table so the residual detector can avoid
/// alarming the user about legitimate background updaters, and can highlight
/// known repeat offenders. Everything not listed is classified `.unknown`
/// ("found — you decide"). This is a hint table, NOT an auto-action list.
enum KnownApps {

    /// Known to leave background helpers running after the app is quit. Matched
    /// case-insensitively against the bundle path.
    private static let offenderNeedles = [
        "baidunetdisk", "baidu",
    ]

    /// Legitimate background services / updaters to leave alone. Matched
    /// case-insensitively against the bundle path.
    private static let benignNeedles = [
        "googlesoftwareupdate", "keystone", "google/google",   // Chrome updater
        "setapp",
        "surge",
        "hypercapslock", "pastepaw",
        "frpc", "pm2",
    ]

    static func classify(bundlePath: String, bundleID: String?) -> ResidualGroup.Classification {
        let haystack = (bundlePath + " " + (bundleID ?? "")).lowercased()
        if offenderNeedles.contains(where: { haystack.contains($0) }) { return .offender }
        // Apple's own system services / widget extensions — its own category so the
        // UI can collapse them away (the user normally doesn't touch Apple's stuff).
        if isAppleSystem(bundlePath: bundlePath, bundleID: bundleID) { return .appleSystem }
        if benignNeedles.contains(where: { haystack.contains($0) }) { return .benign }
        return .unknown
    }

    /// True for Apple's first-party system bundles (by bundle id or system path).
    static func isAppleSystem(bundlePath: String, bundleID: String?) -> Bool {
        if let id = bundleID?.lowercased(), id.hasPrefix("com.apple.") { return true }
        return bundlePath.hasPrefix("/System/")
            || bundlePath.hasPrefix("/Library/Apple/")
            || bundlePath.hasPrefix("/usr/libexec/")
    }
}
