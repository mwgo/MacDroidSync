import AppKit
import MacDroidSyncCore
import UserNotifications

/// Banner shown when a file arrives from the phone, with a "Show in Finder"
/// action.
///
/// Strictly best effort: UNUserNotificationCenter only works inside an app
/// bundle, and an ad-hoc signed build does not always get the authorization
/// prompt. Every path therefore fails silently - the menu bar reports the same
/// transfers and is the reliable channel.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    private static let category = "file-received"
    private static let showInFinder = "show-in-finder"
    private static let pathKey = "path"

    /// Outside an app bundle the notification center traps instead of failing,
    /// so it is never touched in that case (for example when run from the CLI).
    private let isAvailable = Bundle.main.bundleIdentifier != nil
    private var isAuthorized = false

    func requestAuthorization() {
        guard isAvailable else {
            Log.info("No app bundle, notifications are disabled")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reveal = UNNotificationAction(
            identifier: Self.showInFinder,
            title: "Show in Finder",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [reveal],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.info("Notification authorization failed: \(error.localizedDescription)")
            }
            self.isAuthorized = granted
            Log.info("Notifications \(granted ? "allowed" : "not allowed")")
        }
    }

    func fileReceived(at url: URL, from device: String) {
        let content = UNMutableNotificationContent()
        content.title = "File received"
        content.body = "\(url.lastPathComponent) from \(device)"
        content.subtitle = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.pathKey: url.path]
        content.sound = .default
        post(content)
    }

    func fileFailed(name: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "File not received"
        content.body = "\(name): \(reason)"
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent, identifier: String = UUID().uuidString) {
        guard isAvailable, isAuthorized else { return }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.info("Could not post the notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The app is an accessory, so without this the banner would be swallowed
    /// whenever MacDroidSync happens to be the active application.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Both the action and a plain tap reveal the file in Finder.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.showInFinder
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
