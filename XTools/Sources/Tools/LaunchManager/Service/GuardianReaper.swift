import Foundation
import AppKit
import Combine
import Darwin

/// The long-lived enforcer for Guardian rules. Runs for the whole app lifetime
/// (started from the tool's `activate()`), independent of whether the window is
/// open.
///
/// Two triggers, matching the user's design:
///  1. EVENT — when an app the user has a rule for terminates, reap its leftover
///     helpers after a short grace (instant response to "I quit the app").
///  2. POLL — every `pollInterval`, re-check each rule and reap helpers whose
///     owning app isn't running (catches helpers that launchd re-spawns later).
///
/// Continuous reaping is USER-LEVEL only — a background loop can't prompt for a
/// password, so root helpers under a rule are counted/logged but left for the
/// on-demand (password-prompt) path. That's the documented root limitation.
final class GuardianReaper: ObservableObject {

    struct EnforcementInfo {
        let date: Date
        let reaped: Int
        let skippedRoot: Int
    }

    private static let log = FileLog("GuardianReaper")
    private let pollInterval: TimeInterval = 10
    private let terminationGrace: TimeInterval = 1.5

    @Published private(set) var rules: [GuardianRule] = []
    @Published private(set) var lastEnforcement: EnforcementInfo?

    private let queue = DispatchQueue(label: "me.xueshi.xtools.guardian", qos: .utility)
    private let lock = NSLock()
    private var rulesSnapshot: [GuardianRule] = []   // thread-safe copy for the queue
    private var pollTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var started = false

    var activeRuleCount: Int { rules.filter { $0.enabled }.count }

    // MARK: - Lifecycle (call on main)

    func start() {
        guard !started else { return }
        started = true
        setRules(GuardianRuleStore.load())

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleTermination(note)
        }

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.enforce(trigger: "poll")
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Self.log.info("started — \(self.activeRuleCount) active rule(s)")
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        started = false
    }

    deinit { stop() }

    // MARK: - Rule CRUD (call on main)

    func addRule(_ rule: GuardianRule) {
        var next = rules
        // De-dupe by bundle path; replace if already present.
        next.removeAll { $0.appBundlePath == rule.appBundlePath }
        next.append(rule)
        setRules(next)
        Self.log.info("added rule for \(rule.appName)")
        enforce(trigger: "rule-added")
    }

    func removeRule(id: UUID) {
        setRules(rules.filter { $0.id != id })
    }

    func setEnabled(id: UUID, _ enabled: Bool) {
        var next = rules
        guard let idx = next.firstIndex(where: { $0.id == id }) else { return }
        next[idx].enabled = enabled
        setRules(next)
        if enabled { enforce(trigger: "rule-enabled") }
    }

    func hasRule(forBundle bundlePath: String) -> Bool {
        rules.contains { $0.appBundlePath == bundlePath }
    }

    private func setRules(_ new: [GuardianRule]) {
        lock.lock(); rulesSnapshot = new; lock.unlock()
        rules = new
        GuardianRuleStore.save(new)
    }

    private func currentRules() -> [GuardianRule] {
        lock.lock(); defer { lock.unlock() }
        return rulesSnapshot
    }

    // MARK: - Triggers

    private func handleTermination(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Resolve symlinks so this matches rule paths (which come from
        // proc_pidpath's resolved real paths).
        let bundlePath = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
        let bundleID = app.bundleIdentifier
        let matched = currentRules().contains { rule in
            guard rule.enabled else { return false }
            if let bundlePath, rule.appBundlePath == bundlePath { return true }
            if let bundleID, let rid = rule.appBundleID, rid == bundleID { return true }
            return false
        }
        guard matched else { return }
        Self.log.info("matched app terminated — scheduling reap")
        queue.asyncAfter(deadline: .now() + terminationGrace) { [weak self] in
            self?.enforceOnQueue(trigger: "app-terminated")
        }
    }

    private func enforce(trigger: String) {
        queue.async { [weak self] in self?.enforceOnQueue(trigger: trigger) }
    }

    /// The core sweep — runs on `queue` (off the main thread).
    private func enforceOnQueue(trigger: String) {
        let enabled = currentRules().filter { $0.enabled }
        guard !enabled.isEmpty else { return }

        let snapshot = ProcessScanner.snapshot()
        let myUID = getuid()
        var reaped = 0
        var skippedRoot = 0

        for rule in enabled {
            if mainAppRunning(bundlePath: rule.appBundlePath, snapshot: snapshot) { continue }
            let helpers = ProcessScanner.processes(inBundle: rule.appBundlePath, from: snapshot)
            guard !helpers.isEmpty else { continue }

            let userHelpers = helpers.filter { $0.uid == myUID && !$0.runsAsRoot }
            let rootHelpers = helpers.filter { $0.runsAsRoot || $0.uid != myUID }

            if !userHelpers.isEmpty {
                ProcessReaper.reapUser(userHelpers, on: queue)
                reaped += userHelpers.count
                Self.log.info("[\(trigger)] reaped \(userHelpers.count) user helper(s) of \(rule.appName)")
            }
            if !rootHelpers.isEmpty {
                skippedRoot += rootHelpers.count
                Self.log.warn("[\(trigger)] \(rootHelpers.count) root helper(s) of \(rule.appName) need on-demand privileged reap")
            }
        }

        if reaped > 0 || skippedRoot > 0 {
            let info = EnforcementInfo(date: Date(), reaped: reaped, skippedRoot: skippedRoot)
            DispatchQueue.main.async { [weak self] in self?.lastEnforcement = info }
            if reaped > 0 { Analytics.trackLaunchAction(kind: "guardian_reap", scope: "user") }
        }
    }

    /// Path-based "is the main app running?" — thread-safe (no NSWorkspace), so it
    /// is safe to call from the background queue.
    private func mainAppRunning(bundlePath: String, snapshot: [ManagedProcess]) -> Bool {
        guard let mainExec = ProcessScanner.mainExecutablePath(bundlePath: bundlePath) else { return false }
        return snapshot.contains { $0.executablePath == mainExec }
    }
}
