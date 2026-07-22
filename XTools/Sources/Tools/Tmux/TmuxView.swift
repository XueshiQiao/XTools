import SwiftUI

/// Tmux Manager page: a live tree of sessions → windows → panes, with refresh,
/// click-to-jump, and window cross-session move.
///
/// Deliberately self-contained (only needs a `TmuxStore`) so a future hotkey can
/// open this view alone in its own window — no shell chrome required.
struct TmuxView: View {

    @ObservedObject private var store: TmuxStore

    private let autoRefresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    init(store: TmuxStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        List {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            statusSection
            treeSection
        }
        .listStyle(.inset)
        .navigationTitle(L("tool.tmux.title"))
        .searchable(text: $store.query, prompt: Text(L("tmux.search.prompt")))
        .toolbar {
            ToolbarItemGroup {
                Button { store.collapseAll() } label: {
                    Label(L("tmux.collapse"), systemImage: "rectangle.compress.vertical")
                }
                .help(L("tmux.collapse"))
                Button { store.expandAll() } label: {
                    Label(L("tmux.expand"), systemImage: "rectangle.expand.vertical")
                }
                .help(L("tmux.expand"))
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
                .help(L("launch.refresh"))
            }
        }
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in store.refresh() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                Text(statusLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } label: {
                iconLabel("terminal", .teal, L("tmux.status.title"))
            }

            if let err = store.lastError, store.sessions.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.sessions.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("tmux.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.clients.isEmpty {
                Text(L("tmux.status.noClient"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(L("tmux.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        if store.sessions.isEmpty { return L("tmux.status.none") }
        return String(
            format: L("tmux.status.count"),
            store.sessionCount,
            store.windowCount,
            store.paneCount,
            store.clients.count
        )
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeSection: some View {
        let sessions = store.filteredSessions
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            } header: {
                Text(L("tmux.tree.header"))
            }
        } else if !store.sessions.isEmpty {
            Section {
                Text(L("tmux.search.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

    private func sessionRow(_ session: TmuxSessionNode) -> some View {
        DisclosureGroup(isExpanded: store.isSessionExpanded(session.id)) {
            ForEach(session.windows) { window in
                windowRow(window)
            }
        } label: {
            // Single line: icon · name · $id · badges — icon stays vertically with title.
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.teal)
                    .frame(width: 16)
                Text(session.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(session.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if session.attached {
                    badge(L("tmux.badge.attached"), .green)
                }
                Text(String(format: L("tmux.meta.windows"), session.windowCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                jumpButton(target: .session(name: session.name), help: L("tmux.action.jump.session"))
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(L("tmux.action.jump.session")) {
                    store.jump(.session(name: session.name))
                }
            }
        }
    }

    private func windowRow(_ window: TmuxWindowNode) -> some View {
        DisclosureGroup(isExpanded: store.isWindowExpanded(window.id)) {
            ForEach(window.panes) { pane in
                paneRow(pane)
            }
        } label: {
            // Single line. Session name is omitted (parent Disclosure already shows it);
            // window id sits right after the title.
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                Text("\(window.index): \(window.name)")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(window.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if window.active {
                    badge(L("tmux.badge.active"), .blue)
                }
                Text(String(format: L("tmux.meta.panes"), window.panes.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                jumpButton(
                    target: .window(sessionName: window.sessionName, windowID: window.id),
                    help: L("tmux.action.jump.window")
                )
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(L("tmux.action.jump.window")) {
                    store.jump(.window(sessionName: window.sessionName, windowID: window.id))
                }
                let destinations = store.destinationSessions(for: window)
                if !destinations.isEmpty {
                    Menu(L("tmux.action.moveTo")) {
                        ForEach(destinations) { dest in
                            Button(dest.name) {
                                store.moveWindow(window, to: dest)
                            }
                        }
                    }
                } else {
                    Text(L("tmux.action.move.noDest"))
                }
            }
        }
    }

    private func paneRow(_ pane: TmuxPaneNode) -> some View {
        HStack(spacing: 8) {
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
                badge(L("tmux.badge.active"), .purple)
            }
            if !pane.subtitle.isEmpty {
                Text(pane.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            jumpButton(target: .pane(id: pane.id), help: L("tmux.action.jump.pane"))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("tmux.action.jump.pane")) {
                store.jump(.pane(id: pane.id))
            }
        }
        // Double-click the row (not only the button) to jump.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { store.jump(.pane(id: pane.id)) }
        )
    }

    // MARK: - Pieces

    private func jumpButton(target: TmuxTarget, help: String) -> some View {
        Button {
            store.jump(target)
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(help)
        // Whole visible control is tappable (icon + padding), not just the glyph.
        .contentShape(Rectangle())
        .frame(minWidth: 28, minHeight: 22)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                store.actionMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
    }
}
