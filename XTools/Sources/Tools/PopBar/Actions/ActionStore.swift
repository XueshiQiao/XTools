import Foundation
import Combine
import SwiftUI   // for Array.move(fromOffsets:toOffset:) used by reorder

/// Owns the user's configurable capsule actions, persisted as a JSON array under
/// Application Support. Seeds the defaults on first run. Shared by the settings
/// editor (CRUD) and the controller (reads the list when showing the capsule).
final class ActionStore: ObservableObject {

    private static let log = FileLog("PopBar.Actions")

    @Published private(set) var actions: [PopBarActionConfig]

    private static var storeDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("XTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where the list lives NOW. Groups made this file's shape different from the
    /// one below, so it has a different name.
    ///
    /// This is a data-safety measure, not bookkeeping. Both this build and an older
    /// XTools read the same Application Support folder, and an older build's decoder
    /// has never heard of `children`: it drops them on read and then writes the whole
    /// file back without them the next time anything is edited or reordered there.
    /// Every action filed into a group would be gone for good, silently. Since the
    /// older build only ever touches the OLD name, moving to a new one puts the
    /// groups somewhere it cannot reach.
    private let fileURL = storeDirectory.appendingPathComponent("popbar-actions-v2.json")

    /// The pre-groups file. Read once, to carry the user's list forward, and then
    /// left alone forever — never written, never deleted. An older build (or a
    /// rollback) still finds its own list exactly where it left it.
    private let legacyURL = storeDirectory.appendingPathComponent("popbar-actions.json")

    private static let webPreviewMigrationKey = "popbar.migratedWebPreview"
    private static let pathActionsMigrationKey = "popbar.migratedPathActions"
    private static let demoGroupMigrationKey = "popbar.seededDemoGroup"
    private static let sideGroupsMigrationKey = "popbar.seededSideGroups"

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PopBarActionConfig].self, from: data),
           !decoded.isEmpty {
            actions = decoded
        } else if let data = try? Data(contentsOf: legacyURL),
                  let decoded = try? JSONDecoder().decode([PopBarActionConfig].self, from: data),
                  !decoded.isEmpty {
            // First run of a build that knows about groups: carry the existing list
            // forward by COPYING it. The old file stays exactly as it is.
            actions = decoded
            save()
            Self.log.info("migrated \(decoded.count) action(s) from the pre-groups file (the old file is left untouched)")
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

    // MARK: - Two-level list

    /// The rules live in `ActionTree` (pure, no store, no disk) so they can be
    /// exercised on their own; the store only persists and publishes the result.
    typealias DropTarget = ActionTree.DropTarget

    func action(id: String) -> PopBarActionConfig? { ActionTree.action(id: id, in: actions) }
    func parentGroupID(of id: String) -> String? { ActionTree.parentGroupID(of: id, in: actions) }
    func canMove(_ id: String, to target: DropTarget) -> Bool {
        ActionTree.canMove(id, to: target, in: actions)
    }

    /// Move an action. Returns false — changing nothing — when the move isn't
    /// allowed, so the caller can leave the list alone.
    @discardableResult
    func move(_ id: String, to target: DropTarget) -> Bool {
        guard let updated = ActionTree.move(id, to: target, in: actions) else { return false }
        actions = updated
        save()
        return true
    }

    /// Remove a group but keep what was in it: the children take its place at the
    /// top level. The "delete the group, not the actions" half of the delete prompt.
    func dissolveGroup(id: String) {
        guard let updated = ActionTree.dissolve(groupID: id, in: actions) else { return }
        actions = updated
        save()
    }

    // MARK: - CRUD

    func add(_ action: PopBarActionConfig) { actions.append(action); save() }

    func update(_ action: PopBarActionConfig) {
        guard let updated = ActionTree.update(action, in: actions) else { return }
        actions = updated
        save()
    }

    /// Delete an action wherever it lives. Deleting a GROUP deletes its children
    /// with it — callers ask first (see `dissolveGroup` for the other outcome).
    func delete(id: String) {
        guard let updated = ActionTree.remove(id: id, from: actions) else { return }
        actions = updated
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
