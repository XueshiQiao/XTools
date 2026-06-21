import Cocoa

final class MenuBarController: NSObject {

    private static let log = FileLog("MenuBarController")

    private static let iconSymbol = "wrench.and.screwdriver"

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateController: UpdateController
    private lazy var mainWindowController = MainWindowController(appState: appState)

    init(appState: AppState, updateController: UpdateController) {
        self.appState = appState
        self.updateController = updateController
        super.init()
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged(_:)),
            name: .xtoolsLanguageChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func languageChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusItem.menu = self.buildMenu()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: Self.iconSymbol, accessibilityDescription: "XTools")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let titleItem = NSMenuItem(title: "XTools v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

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
    }
}
