import SwiftUI
import UniformTypeIdentifiers

/// The editable action list on the PopBar settings page — two levels deep, with
/// drag and drop as the only way to reorder.
///
/// Two levels, never three. A GROUP holds ordinary actions and is what the wheel
/// unfolds as its second ring; an action inside a group cannot hold anything
/// itself. The rule is enforced twice on purpose: the drop indicator refuses to
/// appear over an illegal target, so an impossible drop never *looks* possible,
/// and `ActionStore.move` refuses the same move again in case anything else ever
/// calls it.
///
/// ### Why drop targets are rows, not the gaps between them
/// A gap would have to be its own view, and inside a grouped `Form` every view is
/// laid out as its own padded row — a 4pt strip would visibly space the list out.
/// So each ROW is the drop target and the intent comes from where in the row the
/// pointer sits: near the top edge → insert above, near the bottom edge → insert
/// below, and the middle of a GROUP row → drop into that group. A plain row has no
/// middle zone, only a top half and a bottom half, so there is nowhere on it that
/// means nothing.
///
/// That needs each row's height, which `DropInfo` does not carry, so every row
/// publishes its own through a preference — never by writing state from inside a
/// `GeometryReader`, which happens during layout and which SwiftUI flags.
///
/// The whole `Section` lives here rather than just the rows, because the
/// preference reader and the delete alert have to attach to the section: hanging
/// them off the `ForEach` instead would wrap it in a single view and collapse
/// fifteen rows into one.
struct PopBarActionListSection: View {

    private static let log = FileLog("PopBar.ActionList")

    @ObservedObject var actions: ActionStore
    /// Opens the editor sheet (the settings page owns it).
    var onEdit: (PopBarActionConfig) -> Void
    /// Row chrome, supplied by the settings page so the two never drift apart.
    var rowContent: (PopBarActionConfig) -> AnyView
    /// The "add action / new group / reset" row at the bottom of the section.
    var footerRow: () -> AnyView

    /// The action being dragged. Only a hint, used to draw the indicator while the
    /// pointer moves — the drop itself goes by the payload (see `performDrop`),
    /// because a drag cancelled outside the window never reports back and would
    /// leave this set.
    @State private var dragging: String?
    /// Where the drop would land right now. Drives the single visible indicator.
    @State private var hint: DropHint?
    /// Row heights, keyed by action id.
    @State private var rowHeights: [String: CGFloat] = [:]
    /// A group the user asked to delete that still has actions in it.
    @State private var groupPendingDelete: PopBarActionConfig?

    /// Marks a dragged payload as one of ours. Anything without it is text from
    /// somewhere else and is ignored.
    fileprivate static let payloadPrefix = "xtools.popbar.action:"
    /// The line that is currently drawn, and which row's delegate put it there.
    ///
    /// Where the line is DRAWN is not always the row the pointer is over. Dropping
    /// on the bottom edge of a group means "after the whole group", which is below
    /// its last CHILD — drawing it under the group's own row would point at the
    /// first child slot instead, and the action would land somewhere the user was
    /// never shown.
    fileprivate struct DropHint: Equatable {
        /// Whose delegate produced this, so only that row clears it again.
        let ownerRowID: String
        /// The row the line is drawn against.
        let rowID: String
        let zone: ActionTree.Zone
        /// Drawn indented, because the action will land INSIDE a group. Two drops
        /// can otherwise put the line in the same place — "append to this group" and
        /// "go after this group" both sit under the last child — and the indent is
        /// what tells them apart.
        let indented: Bool
    }

    /// How far a child row is indented (leading pad + rule + trailing pad).
    private static let childIndent: CGFloat = 26

    /// The types a dropped row may arrive as. `NSItemProvider(object: NSString)`
    /// registers `public.utf8-plain-text` and `public.url` — NOT `public.text` —
    /// and SwiftUI's `of:` list is matched against those identifiers, so listing
    /// only the abstract parent type can leave the delegate never called at all.
    fileprivate static let acceptedTypes: [UTType] = [.utf8PlainText, .plainText, .text, .url]

    var body: some View {
        Section {
            ForEach(rows, id: \.id) { row in
                rowView(row)
            }
            footerRow()
        } header: {
            Text(L("popbar.actions.header"))
        } footer: {
            Text(L("popbar.actions.footer3"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onPreferenceChange(RowHeightKey.self) { rowHeights = $0 }
        // A drag cancelled outside the window never reports back; leaving the page
        // is the one moment we know for certain that it is over.
        .onDisappear { dragging = nil; hint = nil }
        .alert(L("popbar.group.delete.title"),
               isPresented: Binding(get: { groupPendingDelete != nil },
                                    set: { if !$0 { groupPendingDelete = nil } }),
               presenting: groupPendingDelete) { group in
            // A group can hold several configured actions, so deleting one must
            // never quietly take them with it. Both outcomes are offered by name,
            // and the one that keeps them is not the destructive button.
            Button(L("popbar.group.delete.all"), role: .destructive) {
                actions.delete(id: group.id)
            }
            Button(L("popbar.group.delete.keep")) {
                actions.dissolveGroup(id: group.id)
            }
            Button(L("popbar.editor.cancel"), role: .cancel) {}
        } message: { group in
            Text(String(format: L("popbar.group.delete.message"), group.title, group.children.count))
        }
    }

    // MARK: - Rows

    /// The list as drawn: every top-level action, each group immediately followed
    /// by its children. Flattened by `ActionTree` — the same function the drop
    /// resolution uses — rather than nested `ForEach`es, so a drop on any row can
    /// work out its neighbours without walking a tree.
    fileprivate var rows: [ActionTree.FlatRow] { ActionTree.flatten(actions.actions) }

    private func config(_ row: ActionTree.FlatRow) -> PopBarActionConfig? {
        ActionTree.action(id: row.id, in: actions.actions)
    }

    @ViewBuilder
    private func rowView(_ row: ActionTree.FlatRow) -> some View {
        if let action = config(row) {
        HStack(spacing: 0) {
            if row.isChild {
                // The indent IS the "this one is inside that group" signal, so it is
                // part of the row rather than a separate spacer view — it has to
                // travel with the row when it is dragged.
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 2, height: 22)
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
            }
            rowContent(action)
        }
        // The WHOLE row responds, not just the icon, and it is a tap gesture rather
        // than a Button on purpose: a Button inside a row that is also `.onDrag`-
        // able can swallow the drag before it starts.
        .contentShape(Rectangle())
        .onTapGesture { onEdit(action) }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: RowHeightKey.self, value: [action.id: geo.size.height])
            }
        )
        .overlay(alignment: .top) { edgeIndicator(action.id, .above) }
        .overlay(alignment: .bottom) { edgeIndicator(action.id, .below) }
        .overlay { intoIndicator(action.id) }
        .contextMenu {
            Button(L("popbar.action.edit")) { onEdit(action) }
            Button(L("popbar.action.delete"), role: .destructive) { requestDelete(action) }
        }
        .onDrag {
            dragging = action.id
            // The payload names itself, so a drop can tell one of OUR rows from any
            // other text dragged in from another app. `dragging` alone can't: a drag
            // cancelled outside the window never reports back, so it can still be
            // set hours later when something unrelated is dragged over the list.
            // That stale flag may show a stray indicator; it can never move
            // anything, because `performDrop` goes by the payload.
            return NSItemProvider(object: (Self.payloadPrefix + action.id) as NSString)
        }
        .onDrop(of: Self.acceptedTypes, delegate: RowDrop(row: row, list: self))
        }
    }

    // MARK: - Drop indicator

    @ViewBuilder
    private func edgeIndicator(_ id: String, _ zone: ActionTree.Zone) -> some View {
        if let hint, hint.rowID == id, hint.zone == zone {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.leading, hint.indented ? Self.childIndent : 0)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func intoIndicator(_ id: String) -> some View {
        if let hint, hint.rowID == id, hint.zone == .into {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(.vertical, -2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Delete

    private func requestDelete(_ action: PopBarActionConfig) {
        if action.kind == .group && action.hasChildren {
            groupPendingDelete = action
        } else {
            actions.delete(id: action.id)
        }
    }

    // MARK: - Drop resolution

    /// Which zone of `row` the pointer at `y` is in.
    fileprivate func zone(in row: ActionTree.FlatRow, y: CGFloat) -> ActionTree.Zone {
        let height = rowHeights[row.id] ?? 30
        // Only a top-level GROUP has a "drop inside me" middle. Everything else is
        // split in half, so every point on the row means something.
        guard row.isGroup, !row.isChild else {
            return y < height / 2 ? .above : .below
        }
        if y < height * 0.28 { return .above }
        if y > height * 0.72 { return .below }
        return .into
    }

    /// Turn "pointer is on this row, in this zone, and the action will land at this
    /// target" into the line to draw.
    fileprivate func drawnHint(pointerRow: ActionTree.FlatRow, zone: ActionTree.Zone,
                               target: ActionStore.DropTarget) -> DropHint {
        var indented = false
        if case .insideBefore = target { indented = true }
        // "After the whole group" belongs under the group's last child, not under
        // the group's own row.
        if !pointerRow.isChild, zone == .below,
           let group = actions.actions.first(where: { $0.id == pointerRow.id }),
           group.kind == .group, let last = group.children.last {
            return DropHint(ownerRowID: pointerRow.id, rowID: last.id, zone: .below, indented: false)
        }
        return DropHint(ownerRowID: pointerRow.id, rowID: pointerRow.id, zone: zone, indented: indented)
    }

    fileprivate func setHint(_ new: DropHint?) { if hint != new { hint = new } }
    fileprivate func clearHint(ifRow id: String) { if hint?.ownerRowID == id { hint = nil } }
    fileprivate func endDrag() { hint = nil; dragging = nil }
    fileprivate var draggingID: String? { dragging }

    /// One row's drop behaviour. Rebuilt with the view, so it always sees the
    /// current list. Assigning to the view's `@State` through this copy is fine —
    /// the property wrapper's setter is `nonmutating` and writes to shared storage.
    private struct RowDrop: DropDelegate {
        let row: ActionTree.FlatRow
        let list: PopBarActionListSection

        private func resolve(_ info: DropInfo) -> (DropHint, ActionStore.DropTarget)? {
            guard let dragging = list.draggingID else { return nil }
            let all = list.actions.actions
            let zone = list.zone(in: row, y: info.location.y)
            guard let target = ActionTree.target(for: row, zone: zone, in: all),
                  ActionTree.canMove(dragging, to: target, in: all),
                  !ActionTree.isNoOp(dragging, target, in: all)
            else { return nil }
            return (list.drawnHint(pointerRow: row, zone: zone, target: target), target)
        }

        /// Only a drag that started on one of OUR rows is offered anything. Checked
        /// through the marker type rather than the `dragging` flag, because a drag
        /// cancelled outside the window never reports back and leaves that flag set:
        /// without this, an ordinary text drag from another app would be handed an
        /// insertion line for whatever row was abandoned hours earlier.
        /// A drag can only be examined synchronously through its registered TYPES,
        /// and a dragged row arrives as plain text like any other — a private type
        /// registered alongside it does NOT survive SwiftUI's drag pipeline
        /// (measured: the receiving side sees only public.utf8-plain-text and
        /// public.url). So this asks the only question it can answer in time, and
        /// the payload is what actually authorises the move (see `performDrop`).
        ///
        /// The gap that leaves is cosmetic: a drag cancelled outside the window
        /// never reports back, so `dragging` can still be set when unrelated text is
        /// dragged over the list, and it will draw an insertion line that does
        /// nothing when dropped.
        func validateDrop(info: DropInfo) -> Bool { list.draggingID != nil }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // Fires continuously while the pointer moves — nothing may be logged here.
            guard let (hint, _) = resolve(info) else {
                list.clearHint(ifRow: row.id)
                return DropProposal(operation: .forbidden)
            }
            list.setHint(hint)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            list.clearHint(ifRow: row.id)
        }

        /// The drop itself goes by the PAYLOAD, not by `dragging`: the flag is a
        /// synchronous convenience for drawing the indicator, while this is the one
        /// that actually rearranges the user's list.
        ///
        /// Reading the payload is asynchronous, so the landing spot is worked out
        /// here — it depends only on where the pointer is — and the move happens on
        /// main once the id arrives, re-checking that it is still a legal move.
        func performDrop(info: DropInfo) -> Bool {
            defer { list.endDrag() }
            let zone = list.zone(in: row, y: info.location.y)
            guard let target = ActionTree.target(for: row, zone: zone, in: list.actions.actions),
                  let provider = info.itemProviders(for: PopBarActionListSection.acceptedTypes).first
            else { return false }
            let store = list.actions
            provider.loadObject(ofClass: NSString.self) { object, error in
                guard let text = object as? NSString else {
                    PopBarActionListSection.log.error("drop: payload unreadable — \(String(describing: error))")
                    return
                }
                let raw = text as String
                // Text dragged in from somewhere else: it never carries the prefix.
                guard raw.hasPrefix(PopBarActionListSection.payloadPrefix) else { return }
                let id = String(raw.dropFirst(PopBarActionListSection.payloadPrefix.count))
                DispatchQueue.main.async {
                    // Re-checked rather than assumed: the list could have changed
                    // between the drop and the payload arriving.
                    guard store.canMove(id, to: target) else { return }
                    let moved = store.move(id, to: target)
                    PopBarActionListSection.log.debug("drop: moved an action → \(target) = \(moved)")
                }
            }
            return true
        }
    }
}

/// Row heights, published upward by each row. A preference rather than a direct
/// write into `@State` from a `GeometryReader`: that write would happen DURING
/// layout, which SwiftUI flags ("Modifying state during view update") and which can
/// feed back into itself.
private struct RowHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
