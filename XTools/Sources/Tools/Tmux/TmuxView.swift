import SwiftUI
import UniformTypeIdentifiers

/// Where the tree is hosted.
enum TmuxPresentation {
    /// Sidebar tab inside the main XTools window (includes hotkey settings).
    case embedded
    /// Floating palette opened by the global hotkey (shell-free).
    case palette
}

/// Tmux Manager page: a live tree of sessions → windows → panes, with refresh,
/// click-to-jump, context-menu move, and drag-and-drop window placement.
///
/// Works embedded in the main window or alone inside the hotkey palette panel —
/// only a `TmuxStore` (and optionally the palette controller for settings) is required.
struct TmuxView: View {

    @ObservedObject private var store: TmuxStore
    @ObservedObject private var palette: TmuxPaletteController
    private let presentation: TmuxPresentation

    private let autoRefresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    init(store: TmuxStore,
         palette: TmuxPaletteController,
         presentation: TmuxPresentation = .embedded) {
        _store = ObservedObject(wrappedValue: store)
        _palette = ObservedObject(wrappedValue: palette)
        self.presentation = presentation
    }

    var body: some View {
        List {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            if presentation == .embedded {
                hotkeySection
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
        .onReceive(autoRefresh) { _ in
            if !store.isDraggingWindow { store.refresh() }
        }
    }

    // MARK: - Hotkey (embedded only)
    // Always on — no toggle, no multi-line copy. Just the recorder (+ conflict hint).

    private var hotkeySection: some View {
        Section {
            LabeledContent {
                HotKeyRecorderField(combo: palette.hotKeyCombo) { combo in
                    palette.hotkeyOccupied = !palette.setHotKey(combo)
                }
            } label: {
                iconLabel("command", .indigo, L("tmux.hotkey.label"))
            }

            if palette.hotkeyOccupied || !palette.isRegistered {
                Text(L("tmux.hotkey.occupied"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("tmux.hotkey.header"))
        }
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
            if presentation == .palette {
                Text(L("tmux.footer.palette"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("tmux.footer"))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            SessionDropLabel(session: session, store: store)
        }
    }

    private func windowRow(_ window: TmuxWindowNode) -> some View {
        DisclosureGroup(isExpanded: store.isWindowExpanded(window.id)) {
            ForEach(window.panes) { pane in
                paneRow(pane)
            }
        } label: {
            WindowDragDropLabel(window: window, store: store)
        }
    }

    private func paneRow(_ pane: TmuxPaneNode) -> some View {
        // Two lines for panes: title row carries the icon (bottom-aligned with
        // text); description sits under the text column with no icon.
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
                    badge(L("tmux.badge.active"), .purple)
                }
                Spacer(minLength: 4)
                jumpButton(target: .pane(id: pane.id), help: L("tmux.action.jump.pane"))
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
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("tmux.action.jump.pane")) {
                store.jump(.pane(id: pane.id))
            }
        }
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

// MARK: - Drag payload

/// Plain-text drag token so we don't need a custom UTType in Info.plist.
/// Shared with the palette tree (`TmuxPaletteTreeView`).
enum TmuxWindowDragToken {
    static let prefix = "xtools.tmux.window:"

    static func encode(windowID: String, name: String) -> String {
        "\(prefix)\(windowID)\t\(name)"
    }

    static func decode(_ raw: String) -> (id: String, name: String)? {
        guard raw.hasPrefix(prefix) else { return nil }
        let rest = String(raw.dropFirst(prefix.count))
        let parts = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let id = parts.first, id.hasPrefix("@"), !id.isEmpty else { return nil }
        let name = parts.count > 1 ? parts[1] : id
        return (id, name)
    }

    /// Returns `true` if a provider was claimed. `completion` is called on the
    /// main queue with a decoded payload, or `onFailure` if the payload is bad.
    static func load(from providers: [NSItemProvider],
                     onFailure: @escaping () -> Void = {},
                     completion: @escaping (String, String) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                guard let raw = object as? String, let parsed = decode(raw) else {
                    onFailure()
                    return
                }
                completion(parsed.id, parsed.name)
            }
        }
        return true
    }
}

// MARK: - Session row (drop → append at end)

private struct SessionDropLabel: View {
    let session: TmuxSessionNode
    @ObservedObject var store: TmuxStore
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
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
                badge(L("tmux.badge.attached"), .green)
            }
            Text(String(format: L("tmux.meta.windows"), session.windowCount))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            jumpButton
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText, UTType.text],
                isTargeted: $isTargeted) { providers in
            let claimed = TmuxWindowDragToken.load(
                from: providers,
                onFailure: { store.endWindowDrag() }
            ) { windowID, name in
                store.moveWindow(
                    id: windowID,
                    name: name,
                    to: .endOfSession(name: session.name),
                    expandSessionID: session.id
                )
            }
            if !claimed { store.endWindowDrag() }
            return claimed
        }
        .contextMenu {
            Button(L("tmux.action.jump.session")) {
                store.jump(.session(name: session.name))
            }
        }
        .help(L("tmux.drop.session.help"))
    }

    private var jumpButton: some View {
        Button {
            store.jump(.session(name: session.name))
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(L("tmux.action.jump.session"))
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
}

// MARK: - Window row (drag source + drop → insert before)

private struct WindowDragDropLabel: View {
    let window: TmuxWindowNode
    @ObservedObject var store: TmuxStore
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(.blue)
                .frame(width: 16, alignment: .center)
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
            jumpButton
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onDrag {
            store.beginWindowDrag()
            let token = TmuxWindowDragToken.encode(windowID: window.id, name: window.name)
            return NSItemProvider(object: token as NSString)
        }
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText, UTType.text],
                isTargeted: $isTargeted) { providers in
            let claimed = TmuxWindowDragToken.load(
                from: providers,
                onFailure: { store.endWindowDrag() }
            ) { windowID, name in
                // Drop onto a window → insert *before* it (takes that slot).
                store.moveWindow(
                    id: windowID,
                    name: name,
                    to: .beforeWindow(id: window.id),
                    expandSessionID: window.sessionID
                )
            }
            if !claimed { store.endWindowDrag() }
            return claimed
        }
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
        .help(L("tmux.drop.window.help"))
    }

    private var jumpButton: some View {
        Button {
            store.jump(.window(sessionName: window.sessionName, windowID: window.id))
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(L("tmux.action.jump.window"))
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
}
