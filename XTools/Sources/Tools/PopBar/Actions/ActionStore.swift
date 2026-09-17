import Foundation
import Combine
import SwiftUI   // for Array.move(fromOffsets:toOffset:) used by reorder

/// Owns the user's configurable capsule actions, persisted as a JSON array under
/// Application Support. Seeds the defaults on first run. Shared by the settings
/// editor (CRUD) and the controller (reads the list when showing the capsule).
final class ActionStore: ObservableObject {

    private static let log = FileLog("PopBar.Actions")

    @Published private(set) var actions: [PopBarActionConfig]

    private let fileURL: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("XTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("popbar-actions.json")
    }()

    private static let webPreviewMigrationKey = "popbar.migratedWebPreview"
    private static let pathActionsMigrationKey = "popbar.migratedPathActions"
    private static let demoGroupMigrationKey = "popbar.seededDemoGroup"
    private static let sideGroupsMigrationKey = "popbar.seededSideGroups"

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PopBarActionConfig].self, from: data),
           !decoded.isEmpty {
            actions = decoded
        } else {
            actions = DefaultActions.seed()
            save()
        }
        migrateWebPreviewIfNeeded()
        migratePathActionsIfNeeded()
        seedDemoGroupIfNeeded()
        seedSideGroupsIfNeeded()
    }

    /// One-time, non-destructive append of the "Web Preview" action for existing
    /// users whose saved list predates it. Runs once (guarded by a flag), never
    /// removes or reorders anything, and is a no-op when the action is already present
    /// (fresh installs seed it). Respects the data-safety rule: only grows the list.
    private func migrateWebPreviewIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.webPreviewMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.webPreviewMigrationKey)
        guard !actions.contains(where: { $0.kind == .webPreview }) else { return }
        actions.append(DefaultActions.webPreviewAction())
        save()
        Self.log.info("migrated: appended Web Preview action to existing list")
    }

    /// Same one-time, append-only treatment for the two path actions (Preview /
    /// Show in Finder). Guarded by its own flag so a user who deletes them doesn't
    /// get them back on the next launch, and each is skipped independently if the
    /// user already made one by hand.
    private func migratePathActionsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.pathActionsMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.pathActionsMigrationKey)
        var added: [String] = []
        if !actions.contains(where: { $0.kind == .quickLook }) {
            actions.append(DefaultActions.quickLookAction())
            added.append("Preview")
        }
        if !actions.contains(where: { $0.kind == .revealInFinder }) {
            actions.append(DefaultActions.revealInFinderAction())
            added.append("Show in Finder")
        }
        guard !added.isEmpty else { return }
        save()
        Self.log.info("migrated: appended \(added.joined(separator: " + ")) to existing list")
    }

    /// One-time, append-only seed of a single demo GROUP so the wheel's second
    /// ring has something to show before groups can be built in settings. Same
    /// contract as the two migrations above: guarded by its own flag (delete it and
    /// it stays deleted), skipped when any group already exists, and it only ever
    /// grows the list — the copied actions stay in place at the top level too.
    private func seedDemoGroupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.demoGroupMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.demoGroupMigrationKey)
        guard !actions.contains(where: { $0.hasChildren }) else { return }
        let group = DefaultActions.demoGroup(from: actions)
        guard group.hasChildren else { return }   // nothing to put in it
        actions.append(group)
        save()
        Self.log.info("seeded: appended demo group '\(group.title)' with \(group.children.count) child action(s)")
    }

    /// Two more demo groups, placed on the RIGHT-hand side of the ring, so both
    /// shapes the submenu can take are reachable while trying it out: a short arc
    /// (3 children) and the case where the children fill a whole turn and the ring
    /// closes up (9 children × 40° = 360°).
    ///
    /// Insertion position is computed, not hard-coded: slices start at twelve
    /// o'clock and run clockwise, so the slice whose bisector is nearest three
    /// o'clock is a quarter of the way round the FINAL list. Append-only in the
    /// sense that matters — every existing action is kept, and the copies inside the
    /// groups are copies, not moves.
    private func seedSideGroupsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.sideGroupsMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.sideGroupsMigrationKey)
        let leaves = actions.filter { !$0.hasChildren && $0.kind != .group }
        guard leaves.count >= 4, actions.filter({ $0.hasChildren }).count < 2 else { return }

        let arcGroup = DefaultActions.group(title: L("popbar.action.group.convert"),
                                            symbol: "arrow.left.arrow.right",
                                            from: Array(leaves.dropFirst(4).prefix(3)))
        let ringGroup = DefaultActions.group(title: L("popbar.action.group.all"),
                                             symbol: "circle.grid.3x3",
                                             from: Array(leaves.prefix(9)))
        let groups = [arcGroup, ringGroup].filter { $0.hasChildren }
        guard !groups.isEmpty else { return }

        let total = actions.count + groups.count
        let anchor = max(0, min(actions.count, Int((Double(total) / 4).rounded()) - 1))
        actions.insert(contentsOf: groups, at: anchor)
        save()
        Self.log.info("seeded: inserted \(groups.count) side group(s) at index \(anchor) of \(total)")
    }

    // MARK: - CRUD

    func add(_ action: PopBarActionConfig) { actions.append(action); save() }

    func update(_ action: PopBarActionConfig) {
        guard let idx = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[idx] = action
        save()
    }

    func delete(id: String) { actions.removeAll { $0.id == id }; save() }

    func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() { actions = DefaultActions.seed(); save() }

    // MARK: - Persistence (atomic)

    private func save() {
        do {
            let data = try JSONEncoder().encode(actions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("save failed: \(error)")
        }
    }
}
