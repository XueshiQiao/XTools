import Foundation
import UserNotifications
import AppKit

/// Announces every profile switch.
///
/// This tool changes the physical keyboard under the user — silently remapping
/// someone's keys is the one thing it must never do — so a switch is always
/// announced, whether the user asked for it or the monitor did it on their
/// behalf.
///
/// Notification Center can be denied or muted by Do Not Disturb, so `lastFailure`
/// records when the banner could not be delivered and the settings page surfaces
/// it. A notification that silently never appears would be worse than none.
///
/// It is also the app's `UNUserNotificationCenter` delegate. macOS suppresses an
/// app's own banners while that app is frontmost unless the delegate asks for
/// them — and the XTools window being open is precisely when a profile switch
/// gets triggered, so without this the notification is swallowed exactly when the
/// user is watching for it. (XTools has no other notification client; if one
/// appears, the delegate belongs in `AppDelegate` and both should route through
/// it.)
final class ROGNotifier: NSObject, UNUserNotificationCenterDelegate {

    private static let log = FileLog("ROGNotifier")

    /// Whether banners can actually be delivered. Starts optimistic so a fresh
    /// launch doesn't flash a "notifications are off" warning during the second
    /// or two — or, if the system prompt is waiting, the minute — before the
    /// answer comes back.
    private(set) var isAuthorized = true

    /// Fired on the main thread whenever the answer changes. The permission
    /// prompt is answered by a human, so the answer can arrive long after launch;
    /// without this the UI would keep showing whatever was true at startup.
    var onAuthorizationChanged: ((Bool) -> Void)?

    var playSound = true

    /// Ask once, at app launch. Denial is not an error — it just means the
    /// settings page shows a hint instead.
    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Self.log.error("authorization failed: \(error.localizedDescription)")
            } else {
                Self.log.info("notification authorization granted=\(granted)")
            }
            self?.update(granted)
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            self?.update(ok)
        }
    }

    private func update(_ authorized: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAuthorized != authorized else { return }
            self.isAuthorized = authorized
            self.onAuthorizationChanged?(authorized)
        }
    }

    func post(title: String, body: String) {
        Self.log.info("notify: \(title) — \(body)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound { content.sound = .default }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("delivery failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(playSound ? [.banner, .sound] : [.banner])
    }
}
