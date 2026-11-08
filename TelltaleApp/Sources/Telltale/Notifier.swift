import Foundation
import OSLog
import UserNotifications

/// Local notifications. Asks for permission the first time one is sent.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let log = Logger(subsystem: "dev.telltale.app", category: "notifications")
    private let center = UNUserNotificationCenter.current()
    /// Called with the start time of the event a clicked notification was about.
    var onOpenEvent: ((Date) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Prompts if permission has not been decided yet, and returns the resulting status.
    func ensureAuthorized() async -> UNAuthorizationStatus {
        let before = await center.notificationSettings().authorizationStatus
        if before == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            Self.log.info("authorization requested, granted=\(granted)")
        }
        let status = await center.notificationSettings().authorizationStatus
        Self.log.info("authorization status=\(status.rawValue)")
        return status
    }

    /// Returns false if notifications are not allowed or delivery failed.
    func send(title: String, body: String, sound: Bool, id: String = UUID().uuidString,
              eventStart: Date? = nil) async -> Bool {
        guard await ensureAuthorized() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let eventStart { content.userInfo = ["eventStart": eventStart.timeIntervalSince1970] }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            Self.log.info("sent \(id)")
            return true
        } catch {
            Self.log.error("send failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A menu bar app is never "frontmost" in the usual sense; without this, banners would be swallowed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification opens the History window at the event it was about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let seconds = response.notification.request.content.userInfo["eventStart"] as? Double else { return }
        await MainActor.run { self.onOpenEvent?(Date(timeIntervalSince1970: seconds)) }
    }

    func currentStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
}
