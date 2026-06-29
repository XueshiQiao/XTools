import Cocoa
import SwiftUI

// MARK: - MainWindowController
//
// Hosts the SwiftUI UI (`MainView`) in a single window with a native sidebar,
// matching AnyDrag's PreferencesWindowController. Closing hides the window
// rather than terminating — XTools is a menu-bar accessory app.
final class MainWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let root = MainView().environmentObject(appState)
        let hosting = NSHostingController(rootView: root)

        window = NSWindow(contentViewController: hosting)
        window.title = "XTools"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 620))
        window.setFrameAutosaveName("XToolsMain")
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        // Bring the settings window to the front from the menu bar. ORDER MATTERS on
        // macOS 14+ (cooperative activation): order the window front FIRST, THEN
        // activate the app. Doing it the other way round (activate → makeKeyAndOrderFront)
        // routinely left the window BEHIND the previously-frontmost app (e.g. Chrome),
        // because the system defers the activation while the order-front already ran.
        // This is the proven approach from the sibling regular (Dock) app HyperCapslock;
        // no reactivation retry loop is needed.
        //
        // We deliberately do NOT use `orderFrontRegardless`: it fronts the window
        // WITHOUT keying it (only the ACTIVE app can own a key window), which broke
        // text-field focus app-wide before — keystrokes leaked to the previously-active
        // app.
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileLog("MainWindow").debug("window shown — windowNumber=\(self.window.windowNumber)")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}

// MARK: - Root view

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selection) {
                Section {
                    builtinRow(.dashboard, symbol: "square.grid.2x2.fill", color: .blue, title: L("dashboard.title"))
                }
                Section {
                    ForEach(appState.tools, id: \.id) { tool in
                        toolRow(tool)
                    }
                }
                Section {
                    builtinRow(.models, symbol: "brain.head.profile", color: .indigo, title: L("models.title"))
                    builtinRow(.general, symbol: "gearshape.fill", color: Color(nsColor: .systemGray), title: L("General"))
                    builtinRow(.about, symbol: "info.circle.fill", color: .pink, title: L("About"))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 250)
            .safeAreaInset(edge: .top, spacing: 0) { brand }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusFooter }
        } detail: {
            detail
                .accessibilityIdentifier("page.\(appState.selection.axID)")
                .environment(\.defaultMinListRowHeight, 34)
                .scrollContentBackground(.hidden)
                .auroraBackground()
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: toggleSidebar) { Image(systemName: "sidebar.leading") }
                            .help(L("nav.toggleSidebar"))
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 540)
        // Re-key the whole tree when the in-app language changes so every
        // NSLocalizedString-derived label re-reads. `selection` is store-backed,
        // so the selected page survives the rebuild.
        .id(appState.languageRevision)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .dashboard:
            DashboardView()
        case .tool(let id):
            if let tool = appState.tool(for: id) {
                tool.makeRootView()
            } else {
                Text(verbatim: "Unknown tool: \(id)")
            }
        case .models:
            ModelsPage(settings: appState.llm.settings)
        case .general:
            GeneralPage()
        case .about:
            AboutPage()
        }
    }

    private func toolRow(_ tool: any XToolModule) -> some View {
        HStack(spacing: 9) {
            SidebarIcon(symbol: tool.symbol, color: tool.color)
            Text(tool.title)
        }
        .padding(.vertical, 2)
        .tag(SidebarItem.tool(tool.id))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.tool_\(tool.id)")
    }

    private func builtinRow(_ item: SidebarItem, symbol: String, color: Color, title: String) -> some View {
        HStack(spacing: 9) {
            SidebarIcon(symbol: symbol, color: color)
            Text(title)
        }
        .padding(.vertical, 2)
        .tag(item)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.\(item.axID)")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable().frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("XTools").font(.system(size: 14, weight: .bold))
                Text("v\(appVersion)").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var statusFooter: some View {
        HStack(spacing: 7) {
            StatusDot(active: true)
            Text(L("status.ready"))
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
