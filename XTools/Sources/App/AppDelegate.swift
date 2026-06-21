import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let updateController = UpdateController()
    private var appState: AppState?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: show a Dock icon + the normal app menu, while ALSO keeping
        // the menu-bar status item. (XTools is a windowed utility, not a pure agent.)
        NSApp.setActivationPolicy(.regular)

        // Install the user's language override before anything reads a localized string.
        Preferences.applyLanguageOverride()

        // Initialize analytics ASAP (inert until a real appKey is configured).
        Analytics.start()

        Self.log.info("launch")

        // The root app model owns the tool registry and starts each tool's
        // app-lifetime background work (e.g. the Launch Manager's Guardian
        // reaper) — this happens here, not when the window opens, so guardian
        // rules are enforced even with the settings window closed.
        let state = AppState(updateController: updateController)
        appState = state

        menuBarController = MenuBarController(appState: state, updateController: updateController)

        // Show the main window on launch (normal windowed-app behavior).
        DispatchQueue.main.async { [weak self] in self?.menuBarController?.showMainWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
        Analytics.flush()
    }

    /// Clicking the Dock icon (with no window open) re-opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuBarController?.showMainWindow() }
        return true
    }
}
