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
    private static let decisionCategory = "photo-decision"
    private static let reviewPhotos = "review-photos"
    /// One fixed identifier, so a new banner about the same standing list
    /// replaces the previous one instead of piling up behind it.
    private static let decisionIdentifier = "photo-decision"

    /// The banner asked for the photo sync window.
    var onOpenPhotoSync: (() -> Void)?
    /// A message banner was clicked: open that conversation.
    var onOpenMessages: ((Int64) -> Void)?

    private static let messageCategory = "sms-received"
    private static let showMessage = "show-message"
    private static let threadKey = "thread"

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
        let review = UNNotificationAction(
            identifier: Self.reviewPhotos,
            title: "Review…",
            options: [.foreground]
        )
        let showMessage = UNNotificationAction(
            identifier: Self.showMessage,
            title: "Show",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.messageCategory,
                actions: [showMessage],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.category,
                actions: [reveal],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.decisionCategory,
                actions: [review],
                intentIdentifiers: [],
                options: []
            ),
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

    func appUpdated(to version: String) {
        let content = UNMutableNotificationContent()
        content.title = "MacDroidSync updated"
        content.body = "Now running version \(version)."
        content.sound = nil
        post(content)
    }

    /// One banner per conversation: a second message from the same person
    /// replaces the first rather than stacking up.
    func messageReceived(thread: SmsThread, messages: [SmsMessage], photo: NSImage? = nil) {
        guard let last = messages.last else { return }
        let content = UNMutableNotificationContent()
        content.title = thread.title
        if let text = last.text, !text.isEmpty {
            content.body = text
        } else {
            content.body = last.images?.isEmpty == false ? "Photo" : "Message"
        }
        if messages.count > 1 {
            content.subtitle = "\(messages.count) new messages"
        }
        content.categoryIdentifier = Self.messageCategory
        content.threadIdentifier = "sms-\(thread.id)"
        content.userInfo = [Self.threadKey: NSNumber(value: thread.id)]
        content.sound = .default
        if let avatar = avatarAttachment(for: thread, photo: photo) {
            content.attachments = [avatar]
        }
        post(content, identifier: "sms-\(thread.id)")
    }

    /// The notification center moves the file into its own store, so a fresh
    /// temporary copy is written for every banner.
    private func avatarAttachment(for thread: SmsThread, photo: NSImage?) -> UNNotificationAttachment? {
        guard let png = SmsAvatar.notificationPNG(for: thread, photo: photo) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sms-avatar-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "avatar", url: url)
        } catch {
            Log.info("Could not attach the avatar: \(error.localizedDescription)")
            return nil
        }
    }

    func fileFailed(name: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "File not received"
        content.body = "\(name): \(reason)"
        post(content)
    }

    /// Says that photos are waiting, and nothing more: the window is where the
    /// decision is made, and this is not urgent enough for a sound.
    func photosNeedDecision(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Photos waiting for a decision"
        content.body = summary
        content.categoryIdentifier = Self.decisionCategory
        content.sound = nil
        post(content, identifier: Self.decisionIdentifier)
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

    /// Both the action and a plain tap do the obvious thing for that banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        if response.notification.request.content.categoryIdentifier == Self.messageCategory {
            guard response.actionIdentifier == Self.showMessage
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                let thread = response.notification.request.content.userInfo[Self.threadKey] as? NSNumber
            else { return }
            DispatchQueue.main.async { [weak self] in self?.onOpenMessages?(thread.int64Value) }
            return
        }
        if response.notification.request.content.categoryIdentifier == Self.decisionCategory {
            guard response.actionIdentifier == Self.reviewPhotos
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
            else { return }
            DispatchQueue.main.async { [weak self] in self?.onOpenPhotoSync?() }
            return
        }
        guard response.actionIdentifier == Self.showInFinder
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
