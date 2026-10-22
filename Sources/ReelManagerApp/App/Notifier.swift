import Foundation
import UserNotifications
import ReelCore

/// Mac notifications for post results. Does nothing when the app runs
/// without a bundle (e.g. `swift run`), where the notification center isn't available.
@MainActor
final class Notifier {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
