import Foundation
import UserNotifications

/// macOS notifications for task events (FR56): run finished / failed / plan
/// awaiting approval. Click-through reveals the task on the board.
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {

    var onOpenTask: ((UUID) -> Void)?
    private var authorized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(message: String, taskId: UUID) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Glance Tasks"
        content.body = message
        content.userInfo = ["taskId": taskId.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the app is "active" (menu-bar app is always active).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["taskId"] as? String,
           let id = UUID(uuidString: raw) {
            DispatchQueue.main.async { [weak self] in self?.onOpenTask?(id) }
        }
        completionHandler()
    }
}
