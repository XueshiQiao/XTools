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
