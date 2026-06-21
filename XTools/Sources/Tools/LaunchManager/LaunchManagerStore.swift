import SwiftUI
import AppKit
import Combine
import Darwin

/// The UI-facing model for the Launch Manager page. Owns the scanned data
/// (residual groups + launchd inventory) and coordinates user actions; the
/// long-lived `GuardianReaper` (passed in, owned by the tool) owns the rules and
/// continuous enforcement.
final class LaunchManagerStore: ObservableObject {

    let reaper: GuardianReaper

    @Published private(set) var residualGroups: [ResidualGroup] = []
    @Published private(set) var launchItems: [LaunchItem] = []
    @Published private(set) var isScanning = false
    @Published var actionMessage: String?

    private static let log = FileLog("LaunchManagerStore")
    private let work = DispatchQueue(label: "me.xueshi.xtools.launchmgr", qos: .userInitiated)

    init(reaper: GuardianReaper) {
        self.reaper = reaper
    }

    // MARK: - Scan

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            guard let self else { return }
            let snapshot = ProcessScanner.snapshot()
            let items = LaunchInventory.scan()
            DispatchQueue.main.async {
                // ResidualDetector consults NSWorkspace → run on main.
                self.residualGroups = ResidualDetector.detect(from: snapshot)
                self.launchItems = items
                self.isScanning = false
            }
        }
    }

    // MARK: - Reaping

    /// Reap one residual group. User helpers are killed silently; root helpers
    /// (if any) go through one admin password prompt.
    func reap(group: ResidualGroup) {
        let myUID = getuid()
        let userProcs = group.helpers.filter { $0.uid == myUID && !$0.runsAsRoot }
        let rootPids = group.helpers.filter { $0.runsAsRoot || $0.uid != myUID }.map { $0.pid }

        // Count only the processes SIGTERM actually reached.
        let userCount = userProcs.isEmpty ? 0 : ProcessReaper.reapUser(userProcs).count
        if userCount > 0 {
            Analytics.trackLaunchAction(kind: "reap", scope: "user")
        }

        if rootPids.isEmpty {
            finishReap(appName: group.appName, count: userCount, rootError: nil)
            return
        }

        work.async { [weak self] in
            let result = ProcessReaper.reapRootPrivileged(pids: rootPids)
            Analytics.trackLaunchAction(kind: "reap", scope: "root")
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.finishReap(appName: group.appName, count: userCount + rootPids.count, rootError: nil)
                case .failure(let err):
                    self?.finishReap(appName: group.appName, count: userCount, rootError: err)
                }
            }
        }
    }

    private func finishReap(appName: String, count: Int, rootError: Error?) {
        if let rootError {
            actionMessage = String(format: L("launch.msg.reapPartial"), appName) + " — \(rootError.localizedDescription)"
        } else {
            actionMessage = String(format: L("launch.msg.reaped"), count, appName)
        }
        // Give the kills a moment to take effect, then re-scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.refresh() }
    }

    // MARK: - Guardian rules

    func createRule(from group: ResidualGroup) {
        let rule = GuardianRule(appName: group.appName,
                                appBundlePath: group.appBundlePath,
                                appBundleID: group.appBundleID)
        // addRule enforces asynchronously. We do NOT claim a reaped count here —
        // the real number is published by the reaper (shown in the Guardian status
        // row's "last reap"); claiming the snapshot count could overstate it.
        reaper.addRule(rule)
        actionMessage = String(format: L("launch.msg.ruleCreated"), group.appName)
        // Re-scan after the reap lands so the now-clean group leaves the residual list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.refresh() }
    }

    func hasRule(for group: ResidualGroup) -> Bool {
        reaper.hasRule(forBundle: group.appBundlePath)
    }

    func toggleRule(_ rule: GuardianRule) {
        reaper.setEnabled(id: rule.id, !rule.enabled)
    }

    func deleteRule(_ rule: GuardianRule) {
        reaper.removeRule(id: rule.id)
    }

    // MARK: - Launch item actions

    func bootout(_ item: LaunchItem) {
        runItemAction(item, kind: "bootout") { LaunchControl.bootout(item) }
    }

    func disablePersistently(_ item: LaunchItem) {
        runItemAction(item, kind: "disable") { LaunchControl.disablePersistently(item) }
    }

    /// Stop now AND prevent reload — the right fix for KeepAlive jobs.
    func disableCompletely(_ item: LaunchItem) {
        runItemAction(item, kind: "disable_completely") { LaunchControl.disableCompletely(item) }
    }

    private func runItemAction(_ item: LaunchItem, kind: String, _ action: @escaping () -> Result<String, Error>) {
        work.async { [weak self] in
            let result = action()
            Analytics.trackLaunchAction(kind: kind, scope: item.plistRequiresRoot ? "root" : "user")
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.actionMessage = String(format: L("launch.msg.itemDone"), item.label)
                case .failure(let err):
                    self?.actionMessage = String(format: L("launch.msg.itemFailed"), item.label) + " — \(err.localizedDescription)"
                }
                self?.refresh()
            }
        }
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
