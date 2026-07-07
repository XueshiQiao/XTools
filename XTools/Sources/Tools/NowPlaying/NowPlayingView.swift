import SwiftUI
import AppKit

/// The Now Playing page: which apps are currently playing audio, to which
/// output device, for how long — with a one-tap "quit app" (the only way to
/// stop another app's sound) and "reveal in Finder".
struct NowPlayingView: View {

    @ObservedObject private var store: NowPlayingStore
    @State private var pendingQuit: AudioSource?

    // Faster than Wake Locks' 5s — "now playing" should feel live.
    private let autoRefresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    init(store: NowPlayingStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            if let message = store.actionMessage {
                Section { messageBanner(message) }
            }
            statusSection
            if !store.sources.isEmpty {
                Section {
                    ForEach(store.sources) { sourceRow($0) }
                } header: {
                    Text(L("nowplaying.header"))
                } footer: {
                    Text(L("nowplaying.footer")).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.nowplaying.title"))
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: {
                    Label(L("launch.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
        .onAppear { store.refresh() }
        .onReceive(autoRefresh) { _ in store.refresh() }
        .confirmationDialog(
            L("nowplaying.quit.confirm.title"),
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            presenting: pendingQuit
        ) { source in
            Button(L("nowplaying.quit.confirm.action"), role: .destructive) {
                store.quit(source); pendingQuit = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingQuit = nil }
        } message: { source in
            Text(String(format: L("nowplaying.quit.confirm.message"), source.processName))
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                Text(store.sources.isEmpty
                     ? L("nowplaying.status.none")
                     : String(format: L("nowplaying.status.count"), store.sources.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.sources.isEmpty ? .green : .pink)
            } label: {
                iconLabel("waveform", store.sources.isEmpty ? .green : .pink, L("nowplaying.status.title"))
            }
            if store.sources.isEmpty {
                Text(store.isScanning ? L("launch.scanning") : L("nowplaying.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Row

    private func sourceRow(_ source: AudioSource) -> some View {
        HStack(spacing: 10) {
            icon(for: source)
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.processName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if source.runsAsRoot {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(source.devices.isEmpty ? L("nowplaying.output.unknown") : source.devices.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if let held = source.heldFor {
                    Text(String(format: L("nowplaying.playing"), AudioSource.durationText(held)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { pendingQuit = source } label: {
                Label(L("nowplaying.quit"), systemImage: "stop.circle")
            }
            .controlSize(.small)
            .disabled(!source.canEnd)
            .help(source.canEnd ? L("nowplaying.quit") : L("nowplaying.root.hint"))
            Menu {
                Button {
                    store.revealInFinder(source)
                } label: {
                    Label(L("nowplaying.reveal"), systemImage: "folder")
                }
                .disabled(source.executablePath == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help(L("nowplaying.reveal"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                store.revealInFinder(source)
            } label: {
                Label(L("nowplaying.reveal"), systemImage: "folder")
            }
            .disabled(source.executablePath == nil)
        }
    }

    private func icon(for source: AudioSource) -> Image {
        // Icon resolution (running app → owning .app bundle → executable →
        // generic glyph) lives on `AudioSource.appIcon`, shared with the
        // Dashboard card.
        Image(nsImage: source.appIcon)
    }

    // MARK: - Pieces

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.actionMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}
