import SwiftUI
import AppKit

/// Pop Bar used to live here: select text anywhere → a capsule of actions pops up
/// at the cursor, plus Screenshot OCR. It has since moved out into its own app,
/// **QDuo** (github.com/XueshiQiao/qduo), and the implementation was removed from
/// XTools. What remains is this sidebar entry, so people who knew the tool find
/// out where it went instead of finding it silently gone.
///
/// No background work: XTools no longer watches the selection. The old
/// `popbar.*` UserDefaults are left untouched (QDuo does not read them, but they
/// are the user's data and cost nothing to keep).
final class PopBarTool: XToolModule {

    let id = "popbar"
    var title: String { L("tool.popbar.title") }
    let symbol = "text.bubble.fill"
    let color = Color.indigo
    let group = ToolGroup.selection

    func makeRootView() -> AnyView { AnyView(PopBarMovedView()) }
}

/// The "this moved to QDuo" page: what happened, and a way to get QDuo — open it
/// when it is installed, otherwise its download page and a Homebrew one-liner.
private struct PopBarMovedView: View {

    private static let qduoBundleID = "me.xueshi.qduo"
    private static let downloadURL = URL(string: "https://xueshi.dev/qduo/")!
    /// Full tap path on purpose: Homebrew refuses a short cask name from a tap
    /// the user has not trusted yet, but accepts one named in full.
    private static let brewCommand = "brew install --cask XueshiQiao/tap/qduo"

    /// Re-read whenever the page appears, so installing QDuo and coming back
    /// flips the page to "Open QDuo" without restarting XTools.
    @State private var qduoURL: URL?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    icon
                    Text(L("popbar.moved.title"))
                        .font(.title3).fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    Text(L("popbar.moved.body"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                if let qduoURL {
                    HStack {
                        iconLabel("checkmark.circle.fill", .green, L("popbar.moved.installed"))
                        Spacer()
                        Button(L("popbar.moved.open")) { open(qduoURL) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        iconLabel("arrow.down.circle.fill", .indigo, L("popbar.moved.download"))
                        Spacer()
                        Button(L("popbar.moved.download")) { NSWorkspace.shared.open(Self.downloadURL) }
                            .buttonStyle(.borderedProminent)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("popbar.moved.brew")).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text(Self.brewCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button(copied ? L("popbar.moved.copied") : L("popbar.moved.copy")) { copyBrewCommand() }
                        }
                    }
                }
            } footer: {
                Text(L("popbar.moved.settingsNote"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("tool.popbar.title"))
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// QDuo's own icon when it is installed; the tool's symbol otherwise.
    @ViewBuilder private var icon: some View {
        if let qduoURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: qduoURL.path))
                .resizable().frame(width: 72, height: 72)
        } else {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 40))
                .foregroundStyle(.indigo)
                .frame(width: 72, height: 72)
        }
    }

    private func refresh() {
        qduoURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.qduoBundleID)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.brewCommand, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
