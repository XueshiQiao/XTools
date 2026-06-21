import Foundation
import AppKit

/// Groups currently-running processes by their owning `.app` bundle and returns
/// the groups whose MAIN app is not running — the "ghost helper" case. Purely
/// informational; the user decides what to do with each group.
enum ResidualDetector {

    static func detect(from snapshot: [ManagedProcess]) -> [ResidualGroup] {
        let ownBundlePath = Bundle.main.bundlePath

        // Bucket every process that lives inside some .app bundle.
        var byBundle: [String: [ManagedProcess]] = [:]
        for proc in snapshot {
            guard let bundle = proc.owningAppBundlePath else { continue }
            if bundle == ownBundlePath { continue }   // never flag ourselves
            byBundle[bundle, default: []].append(proc)
        }

        var groups: [ResidualGroup] = []
        for (bundlePath, procs) in byBundle {
            let bundleID = Bundle(path: bundlePath)?.bundleIdentifier
            // Residual only if the main app itself is NOT running.
            if ProcessScanner.isMainAppRunning(bundlePath: bundlePath, bundleID: bundleID, snapshot: snapshot) {
                continue
            }
            // Exclude the bundle's own main-executable process from "helpers"
            // (it's nil here anyway since the main app isn't running, but be safe).
            let mainExec = ProcessScanner.mainExecutablePath(bundlePath: bundlePath)
            let helpers = procs.filter { $0.executablePath != mainExec }
            guard !helpers.isEmpty else { continue }

            let appName = (Bundle(path: bundlePath)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let classification = KnownApps.classify(bundlePath: bundlePath, bundleID: bundleID)

            groups.append(ResidualGroup(
                appBundlePath: bundlePath,
                appName: appName,
                appBundleID: bundleID,
                helpers: helpers.sorted { $0.pid < $1.pid },
                classification: classification
            ))
        }

        // Offenders first, then unknowns, then 3rd-party benign, then Apple last.
        func rank(_ c: ResidualGroup.Classification) -> Int {
            switch c {
            case .offender:    return 0
            case .unknown:     return 1
            case .benign:      return 2
            case .appleSystem: return 3
            }
        }
        return groups.sorted {
            rank($0.classification) != rank($1.classification)
                ? rank($0.classification) < rank($1.classification)
                : $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }
}
