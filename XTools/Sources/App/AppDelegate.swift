import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let updateController = UpdateController()
    private var appState: AppState?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

        // Dev affordance: open the window on launch when XTOOLS_AUTOOPEN is set
        // (used for screenshots/verification). Inert in normal use.
        if ProcessInfo.processInfo.environment["XTOOLS_AUTOOPEN"] != nil {
            DispatchQueue.main.async { [weak self] in self?.menuBarController?.showMainWindow() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
        Analytics.flush()
    }
}
