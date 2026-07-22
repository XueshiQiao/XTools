import SwiftUI
import UniformTypeIdentifiers

/// Shell-free tree for the hotkey palette: sessions → windows → panes only.
///
/// Background note: lag is entirely about the *window fill* (live glass / material
/// sampling). Drag gesture placement is unrelated — whole-row `onDrag` is fine.
struct TmuxPaletteTreeView: View {

    @ObservedObject var store: TmuxStore

    private let autoRefresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.sessions.isEmpty {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(store.sessions) { session in
                        sessionBlock(session)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .animation(nil, value: store.expandedSessions)
            .animation(nil, value: store.expandedWindows)
        }
        .scrollContentBackground(.hidden)
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in
            if !store.isDraggingWindow { store.refresh() }
        }
    }

    private var emptyMessage: String {
        if store.isScanning { return L("launch.scanning") }
        if let err = store.lastError, !err.isEmpty { return err }
        return L("tmux.empty")
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
                    .padding(.leading, 12)
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
                .padding(.leading, 12)
            }
        }
    }
}

// MARK: - Jump button (roomy hit box, compact visual)

private struct PaletteJumpButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Session row

private struct PaletteSessionRow: View {
    let session: TmuxSessionNode
    let expanded: Bool
    let onToggle: () -> Void
    let onJump: () -> Void
    let onDropWindow: (String, String) -> Void
    let onDropFailed: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.teal)
                        .frame(width: 16)
                    Text(session.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

            PaletteJumpButton(help: L("tmux.action.jump.session"), action: onJump)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
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

// MARK: - Window row (whole-row drag)

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
        HStack(alignment: .center, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "macwindow")
                        .foregroundStyle(.blue)
                        .frame(width: 16)
                    Text("\(window.index): \(window.name)")
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? L("tmux.collapse") : L("tmux.expand"))

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

            PaletteJumpButton(help: L("tmux.action.jump.window"), action: onJump)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        // Whole-row drag (not a separate grip). Lag was background-only.
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
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.purple)
                    .frame(width: 16)

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

                PaletteJumpButton(help: L("tmux.action.jump.pane"), action: onJump)
            }

            if !pane.subtitle.isEmpty {
                Text(pane.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("tmux.action.jump.pane"), action: onJump)
        }
    }
}

// MARK: - Shared

private func paletteBadge(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
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
