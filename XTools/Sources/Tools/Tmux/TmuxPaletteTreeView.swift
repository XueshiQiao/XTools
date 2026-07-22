import SwiftUI
import UniformTypeIdentifiers

/// Shell-free tree for the hotkey palette: no chrome, no status, no section
/// headers — only sessions → windows → panes on a liquid-glass panel.
///
/// Interaction:
/// - Single-click a collapsible row → expand / collapse
/// - Double-click any row → jump (session / window / pane)
/// - Jump arrows still work
/// - Window drag-and-drop still works
///
/// Drag performance notes:
/// - Window rows must NOT attach delayed single-tap gestures on the same view as
///   `onDrag` (SwiftUI waits to disambiguate tap vs drag → sticky drag start).
/// - Rows take plain values + closures, not `@ObservedObject store`, so drag-state
///   / refresh churn does not re-render the whole tree.
struct TmuxPaletteTreeView: View {

    @ObservedObject var store: TmuxStore

    private let autoRefresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if store.sessions.isEmpty {
                    Text(store.isScanning ? L("launch.scanning") : L("tmux.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(store.sessions) { session in
                        sessionBlock(session)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in
            if !store.isDraggingWindow { store.refresh() }
        }
    }

    // MARK: - Session

    @ViewBuilder
    private func sessionBlock(_ session: TmuxSessionNode) -> some View {
        let expanded = store.expandedSessions.contains(session.id)

        PaletteSessionRow(
            session: session,
            expanded: expanded,
            onToggle: { store.toggleSessionExpanded(session.id) },
            onJump: { store.jump(.session(name: session.name)) },
            onDropWindow: { windowID, name in
                store.moveWindow(
                    id: windowID, name: name,
                    to: .endOfSession(name: session.name),
                    expandSessionID: session.id
                )
            },
            onDropFailed: { store.endWindowDrag() }
        )

        if expanded {
            ForEach(session.windows) { window in
                windowBlock(window)
                    .padding(.leading, 14)
            }
        }
    }

    // MARK: - Window

    @ViewBuilder
    private func windowBlock(_ window: TmuxWindowNode) -> some View {
        let expanded = store.expandedWindows.contains(window.id)
        let destinations = store.destinationSessions(for: window)

        PaletteWindowRow(
            window: window,
            expanded: expanded,
            destinations: destinations,
            onToggle: { store.toggleWindowExpanded(window.id) },
            onJump: {
                store.jump(.window(sessionName: window.sessionName, windowID: window.id))
            },
            onBeginDrag: { store.beginWindowDrag() },
            onDropWindow: { windowID, name in
                store.moveWindow(
                    id: windowID, name: name,
                    to: .beforeWindow(id: window.id),
                    expandSessionID: window.sessionID
                )
            },
            onDropFailed: { store.endWindowDrag() },
            onMoveToSession: { dest in
                store.moveWindow(window, to: dest)
            }
        )

        if expanded {
            ForEach(window.panes) { pane in
                PalettePaneRow(
                    pane: pane,
                    onJump: { store.jump(.pane(id: pane.id)) }
                )
                .padding(.leading, 14)
            }
        }
    }
}

// MARK: - Expand / jump gesture (session only — NOT on drag sources)

/// Single-click (after a short delay) vs double-click without firing both.
/// Never put this on a view that also has `onDrag`.
private struct SingleDoubleTapModifier: ViewModifier {
    let onSingle: () -> Void
    let onDouble: () -> Void

    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                pending?.cancel()
                pending = nil
                onDouble()
            }
            .onTapGesture(count: 1) {
                pending?.cancel()
                let work = DispatchWorkItem { onSingle() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            }
    }
}

private extension View {
    func singleDoubleTap(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        modifier(SingleDoubleTapModifier(onSingle: single, onDouble: double))
    }
}

// MARK: - Session row (drop target, not a drag source)

private struct PaletteSessionRow: View {
    let session: TmuxSessionNode
    let expanded: Bool
    let onToggle: () -> Void
    let onJump: () -> Void
    let onDropWindow: (String, String) -> Void
    let onDropFailed: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)

            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.teal)
                .frame(width: 16, alignment: .center)

            Text(session.name)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(session.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if session.attached {
                paletteBadge(L("tmux.badge.attached"), .green)
            }

            Text(String(format: L("tmux.meta.windows"), session.windowCount))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            Button(action: onJump) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(L("tmux.action.jump.session"))
            .contentShape(Rectangle())
            .frame(minWidth: 28, minHeight: 22)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        // Session is not dragged — single/double tap is fine here.
        .singleDoubleTap(single: onToggle, double: onJump)
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText, UTType.text],
                isTargeted: $isTargeted) { providers in
            acceptWindowDrop(providers, onFailure: onDropFailed, onOK: onDropWindow)
        }
        .contextMenu {
            Button(L("tmux.action.jump.session"), action: onJump)
        }
        .help(L("tmux.drop.session.help"))
    }
}

// MARK: - Window row (drag source — no delayed single-tap on this view)

private struct PaletteWindowRow: View {
    let window: TmuxWindowNode
    let expanded: Bool
    let destinations: [TmuxSessionNode]
    let onToggle: () -> Void
    let onJump: () -> Void
    let onBeginDrag: () -> Void
    let onDropWindow: (String, String) -> Void
    let onDropFailed: () -> Void
    let onMoveToSession: (TmuxSessionNode) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            // Expand hit target (chevron + icon). Kept as a real Button so it
            // never shares a gesture arena with `onDrag` on the parent.
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .center)
                    Image(systemName: "macwindow")
                        .foregroundStyle(.blue)
                        .frame(width: 16, alignment: .center)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? L("tmux.collapse") : L("tmux.expand"))

            Text("\(window.index): \(window.name)")
                .fontWeight(.medium)
                .lineLimit(1)

            Text(window.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if window.active {
                paletteBadge(L("tmux.badge.active"), .blue)
            }

            Text(String(format: L("tmux.meta.panes"), window.panes.count))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            Button(action: onJump) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(L("tmux.action.jump.window"))
            .contentShape(Rectangle())
            .frame(minWidth: 28, minHeight: 22)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        // Double-click jump only. Do NOT put a delayed single-tap (or a competing
        // DragGesture) on this view — both force SwiftUI to disambiguate against
        // `onDrag` and make the drag feel sticky/janky.
        .onTapGesture(count: 2, perform: onJump)
        .onDrag {
            onBeginDrag()
            let token = TmuxWindowDragToken.encode(windowID: window.id, name: window.name)
            return NSItemProvider(object: token as NSString)
        }
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText, UTType.text],
                isTargeted: $isTargeted) { providers in
            acceptWindowDrop(providers, onFailure: onDropFailed, onOK: onDropWindow)
        }
        .contextMenu {
            Button(L("tmux.action.jump.window"), action: onJump)
            if !destinations.isEmpty {
                Menu(L("tmux.action.moveTo")) {
                    ForEach(destinations) { dest in
                        Button(dest.name) { onMoveToSession(dest) }
                    }
                }
            } else {
                Text(L("tmux.action.move.noDest"))
            }
        }
        .help(L("tmux.drop.window.help"))
    }
}

// MARK: - Pane row

private struct PalettePaneRow: View {
    let pane: TmuxPaneNode
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.purple)
                    .frame(width: 16, alignment: .center)

                Text(pane.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(pane.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if pane.active {
                    paletteBadge(L("tmux.badge.active"), .purple)
                }

                Spacer(minLength: 4)

                Button(action: onJump) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L("tmux.action.jump.pane"))
                .contentShape(Rectangle())
                .frame(minWidth: 28, minHeight: 22)
            }

            if !pane.subtitle.isEmpty {
                Text(pane.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onJump)
        .contextMenu {
            Button(L("tmux.action.jump.pane"), action: onJump)
        }
    }
}

// MARK: - Shared bits

private func paletteBadge(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
}

private func acceptWindowDrop(
    _ providers: [NSItemProvider],
    onFailure: @escaping () -> Void,
    onOK: @escaping (String, String) -> Void
) -> Bool {
    let claimed = TmuxWindowDragToken.load(
        from: providers,
        onFailure: onFailure
    ) { id, name in
        onOK(id, name)
    }
    if !claimed { onFailure() }
    return claimed
}
