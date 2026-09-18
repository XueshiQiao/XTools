import Foundation

/// The two-level action list as pure data: every rule about where an action may
/// go, and what happens when it gets there, with no store, no disk and no UI
/// attached.
///
/// Split out of `ActionStore` deliberately. The store owns persistence and
/// publishing; these are the rules that decide whether a drag is legal and what
/// the list looks like afterwards, and keeping them here means they can be
/// exercised on their own — against a literal array, with no Application Support
/// file to clobber.
///
/// The invariant every operation here preserves: **nothing is ever lost.** A move
/// takes an action out of one place and puts it in exactly one other; the only
/// operation that removes anything is `remove`, which the caller reaches by
/// deleting on purpose.
enum ActionTree {

    /// Where a drag wants to land.
    ///
    /// Stated as "before WHICH action" rather than an index, because a move pulls
    /// the dragged action out first and every index after it shifts by one. An id
    /// survives that; an index does not.
    enum DropTarget: Equatable {
        /// At the top level, before this action (nil = at the very end).
        case topBefore(String?)
        /// Inside this group, before this child (nil = at the end of the group).
        case insideBefore(groupID: String, childID: String?)
    }

    // MARK: - Lookup

    static func action(id: String, in list: [PopBarActionConfig]) -> PopBarActionConfig? {
        if let top = list.first(where: { $0.id == id }) { return top }
        for group in list {
            if let child = group.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    /// The group an action lives in, or nil when it is top-level (or absent).
    static func parentGroupID(of id: String, in list: [PopBarActionConfig]) -> String? {
        for group in list where group.hasChildren {
            if group.children.contains(where: { $0.id == id }) { return group.id }
        }
        return nil
    }

    /// Pull an action out of wherever it is — top level or inside a group.
    @discardableResult
    static func extract(id: String, from list: inout [PopBarActionConfig]) -> PopBarActionConfig? {
        if let i = list.firstIndex(where: { $0.id == id }) { return list.remove(at: i) }
        for g in list.indices {
            if let c = list[g].children.firstIndex(where: { $0.id == id }) {
                return list[g].children.remove(at: c)
            }
        }
        return nil
    }

    // MARK: - Rules

    /// Whether this move is allowed, WITHOUT performing it. The drop indicator asks
    /// first, so an illegal drop shows no landing spot at all rather than snapping
    /// back after the fact.
    static func canMove(_ id: String, to target: DropTarget, in list: [PopBarActionConfig]) -> Bool {
        guard let moving = action(id: id, in: list) else { return false }
        guard case .insideBefore(let groupID, _) = target else { return true }
        // Two levels, never three: a group can't go inside a group. That holds for
        // an EMPTY group too — one rule is easier to live with than "empty ones may,
        // full ones may not", and a group that could never be filled is useless.
        if moving.kind == .group || moving.hasChildren { return false }
        // The destination must still be a real group.
        return list.contains { $0.id == groupID && $0.kind == .group }
    }

    // MARK: - Operations (each returns nil when it would change nothing)

    /// Move an action to `target`. nil = not allowed, leave the list alone.
    static func move(_ id: String, to target: DropTarget,
                     in list: [PopBarActionConfig]) -> [PopBarActionConfig]? {
        guard canMove(id, to: target, in: list) else { return nil }
        var out = list
        guard let moving = extract(id: id, from: &out) else { return nil }
        switch target {
        case .topBefore(let beforeID):
            let idx = beforeID.flatMap { b in out.firstIndex { $0.id == b } } ?? out.count
            out.insert(moving, at: idx)
        case .insideBefore(let groupID, let childID):
            guard let g = out.firstIndex(where: { $0.id == groupID }) else { return nil }
            var child = moving
            child.children = []   // belt and braces; `canMove` already refused a group
            let idx = childID.flatMap { c in out[g].children.firstIndex { $0.id == c } }
                ?? out[g].children.count
            out[g].children.insert(child, at: idx)
        }
        return out
    }

    /// Update an action in place, wherever it lives.
    ///
    /// A group's `children` are NOT taken from the incoming copy: the editor edits a
    /// group's name and icon, never its contents, so an editor sheet opened before a
    /// drag would otherwise write a stale list of children back over the current one
    /// and silently undo the drag.
    static func update(_ action: PopBarActionConfig,
                       in list: [PopBarActionConfig]) -> [PopBarActionConfig]? {
        var out = list
        if let i = out.firstIndex(where: { $0.id == action.id }) {
            var updated = action
            updated.children = out[i].children
            out[i] = updated
            return out
        }
        for g in out.indices {
            if let c = out[g].children.firstIndex(where: { $0.id == action.id }) {
                var child = action
                child.children = []
                out[g].children[c] = child
                return out
            }
        }
        return nil
    }

    /// Delete an action wherever it lives. Deleting a GROUP takes its children with
    /// it, so the caller has to have asked first — `dissolve` is the other half of
    /// that choice.
    static func remove(id: String, from list: [PopBarActionConfig]) -> [PopBarActionConfig]? {
        var out = list
        guard extract(id: id, from: &out) != nil else { return nil }
        return out
    }

    /// Remove a group but KEEP what was in it: the children take its place at the
    /// top level, in order. Nothing the user configured is thrown away.
    static func dissolve(groupID: String, in list: [PopBarActionConfig]) -> [PopBarActionConfig]? {
        guard let g = list.firstIndex(where: { $0.id == groupID }) else { return nil }
        var out = list
        let children = out[g].children
        out.remove(at: g)
        out.insert(contentsOf: children, at: g)
        return out
    }

    // MARK: - The flattened list, and what a drop on one of its rows means

    /// One entry of the list as the settings page draws it: every top-level action,
    /// each group immediately followed by its children.
    struct FlatRow: Equatable {
        let id: String
        let isGroup: Bool
        /// nil = top level; otherwise the group this row sits in.
        let parentID: String?
        var isChild: Bool { parentID != nil }
    }

    /// Which part of a row the pointer is over.
    enum Zone { case above, below, into }

    static func flatten(_ list: [PopBarActionConfig]) -> [FlatRow] {
        list.flatMap { action -> [FlatRow] in
            [FlatRow(id: action.id, isGroup: action.kind == .group, parentID: nil)]
                + action.children.map { FlatRow(id: $0.id, isGroup: false, parentID: action.id) }
        }
    }

    /// Turn "this row, this zone" into the move it stands for. The drop indicator
    /// and the drop itself both go through here, which is what makes the line the
    /// user sees and the place the action lands the same answer.
    static func target(for row: FlatRow, zone: Zone,
                       in list: [PopBarActionConfig]) -> DropTarget? {
        switch (row.isChild, zone) {
        case (false, .above):
            return .topBefore(row.id)
        case (false, .below):
            // Below a GROUP means after the whole group, children included — so the
            // anchor is the next TOP-LEVEL action, not the group's first child.
            guard let i = list.firstIndex(where: { $0.id == row.id }) else { return nil }
            return .topBefore(i + 1 < list.count ? list[i + 1].id : nil)
        case (false, .into):
            guard row.isGroup else { return nil }
            return .insideBefore(groupID: row.id, childID: nil)
        case (true, .above):
            guard let parentID = row.parentID else { return nil }
            return .insideBefore(groupID: parentID, childID: row.id)
        case (true, .below):
            guard let parentID = row.parentID,
                  let group = list.first(where: { $0.id == parentID }),
                  let i = group.children.firstIndex(where: { $0.id == row.id })
            else { return nil }
            let next = i + 1 < group.children.count ? group.children[i + 1].id : nil
            return .insideBefore(groupID: parentID, childID: next)
        case (true, .into):
            return nil   // a child row has no inside
        }
    }

    /// Whether dropping here would change nothing. Landing exactly where it already
    /// is is legal but pointless, and an indicator for it makes the list look like
    /// it is about to move when it isn't.
    static func isNoOp(_ id: String, _ target: DropTarget, in list: [PopBarActionConfig]) -> Bool {
        let parent = parentGroupID(of: id, in: list)
        switch target {
        case .topBefore(let beforeID):
            guard parent == nil, let i = list.firstIndex(where: { $0.id == id }) else { return false }
            let after = i + 1 < list.count ? list[i + 1].id : nil
            return beforeID == id || beforeID == after
        case .insideBefore(let groupID, let childID):
            guard parent == groupID,
                  let group = list.first(where: { $0.id == groupID }),
                  let i = group.children.firstIndex(where: { $0.id == id })
            else { return false }
            let after = i + 1 < group.children.count ? group.children[i + 1].id : nil
            return childID == id || childID == after
        }
    }

    /// Every action in the list, top level and children alike. Used to check that a
    /// rearrangement moved things rather than losing them.
    static func allIDs(_ list: [PopBarActionConfig]) -> [String] {
        list.flatMap { [$0.id] + $0.children.map(\.id) }
    }
}
