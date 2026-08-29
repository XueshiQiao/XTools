import Cocoa
import Combine

final class MenuBarController: NSObject {

    private static let log = FileLog("MenuBarController")

    private static let iconSymbol = "wrench.and.screwdriver"

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateController: UpdateController
    private lazy var mainWindowController = MainWindowController(appState: appState)

    /// The ROG Keyboard tool gets a slice of this menu: switching the keyboard to
    /// its Windows profile has to happen BEFORE the user flips the keyboard's
    /// mode switch, and by then the app window is the last thing they want to go
    /// hunting for.
    private var rogTool: ROGKeyboardTool? { appState.tool(for: "rog-keyboard") as? ROGKeyboardTool }
    private weak var rogStatusItem: NSMenuItem?
    private var rogObserver: AnyCancellable?

    init(appState: AppState, updateController: UpdateController) {
        self.appState = appState
        self.updateController = updateController
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: Self.iconSymbol, accessibilityDescription: "XTools")
            // Left-click opens the main window directly; right-click (or
            // Control-click) pops the menu. The menu is attached on demand in
            // `statusItemClicked` so a permanent `statusItem.menu` doesn't
            // swallow the left-click.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) ?? false
        if isRightClick || isControlClick {
            popUpMenu()
        } else {
            showMainWindow()
        }
    }

    /// Attach the menu just long enough to pop it, then detach so the next
    /// left-click routes back to `statusItemClicked` instead of the menu.
    private func popUpMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let titleItem = NSMenuItem(title: "XTools v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        addROGKeyboardSection(to: menu)

        let settingsItem = NSMenuItem(title: NSLocalizedString("Open XTools…", comment: ""), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 600
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let feedbackItem = NSMenuItem(title: NSLocalizedString("Feedback…", comment: ""), action: #selector(openFeedback(_:)), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        let moreAppsItem = NSMenuItem(title: NSLocalizedString("More Apps by Author…", comment: ""), action: #selector(openAuthorWebsite(_:)), keyEquivalent: "")
        moreAppsItem.target = self
        menu.addItem(moreAppsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("Quit XTools", comment: ""), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    // MARK: - ROG Keyboard section

    /// Current profile (live, not a snapshot from when the menu was built) plus
    /// the two switches. Omitted entirely when the tool isn't registered.
    private func addROGKeyboardSection(to menu: NSMenu) {
        guard let tool = rogTool else { return }

        let status = NSMenuItem(title: rogStatusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        rogStatusItem = status

        let toWindows = NSMenuItem(title: NSLocalizedString("rog.action.switchToWindows", comment: ""),
                                   action: #selector(rogSwitchToWindows(_:)), keyEquivalent: "")
        toWindows.target = self
        menu.addItem(toWindows)

        let toMac = NSMenuItem(title: NSLocalizedString("rog.action.switchToMac", comment: ""),
                               action: #selector(rogSwitchToMac(_:)), keyEquivalent: "")
        toMac.target = self
        menu.addItem(toMac)

        menu.addItem(.separator())

        // The state arrives asynchronously (it takes a HID round-trip), so the
        // row rewrites itself when the answer lands instead of showing whatever
        // was true last time the menu opened.
        rogObserver = tool.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rogStatusItem?.title = self.rogStatusTitle()
            }
    }

    private func rogStatusTitle() -> String {
        guard let store = rogTool?.store else { return "" }
        guard store.isConnected, let info = store.info else {
            return NSLocalizedString("rog.menu.disconnected", comment: "")
        }
        return String(format: NSLocalizedString("rog.menu.current", comment: ""),
                      store.profileLabel(info.currentProfile))
    }

    @objc private func rogSwitchToWindows(_ sender: NSMenuItem) {
        rogTool?.store.switchToWindows()
    }

    @objc private func rogSwitchToMac(_ sender: NSMenuItem) {
        rogTool?.store.switchToMac()
    }

    /// Open the main window programmatically (used by the menu and by the
    /// `XTOOLS_AUTOOPEN` dev affordance in AppDelegate).
    func showMainWindow() {
        mainWindowController.show()
    }

    // MARK: - Actions

    @objc private func openSettings(_ sender: NSMenuItem) {
        mainWindowController.show()
    }

    @objc private func openFeedback(_ sender: NSMenuItem) {
        guard let url = URL(string: "https://xueshasoho.feishu.cn/share/base/form/shrcnZK4KXsAg0w80ERWkf1WoXc") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updateController.checkForUpdates(sender)
    }

    @objc private func openAuthorWebsite(_ sender: NSMenuItem) {
        guard let url = URL(string: "https://xueshi.dev") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let updateItem = menu.item(withTag: 600) {
            updateItem.isEnabled = updateController.canCheckForUpdates
        }
        // Ask the keyboard where it actually is, rather than trusting a reading
        // from before the user last flipped its mode switch.
        rogTool?.store.refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        rogObserver = nil
        rogStatusItem = nil
    }
}
