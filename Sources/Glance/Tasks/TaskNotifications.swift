import Foundation
import UserNotifications

/// Which approval gate a notification represents (FR44.2 plan gate,
/// FR52 review gate). Raw value doubles as the UNNotificationCategory id.
enum TaskGate: String {
    case plan = "gate.plan"
    case review = "gate.review"
}

/// macOS notifications for task events (FR56): run finished / failed / plan
/// awaiting approval. Click-through reveals the task on the board. Gate
/// notifications carry Approve / Reject action buttons so review costs one
/// click (reject offers a text field for the reason).
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {

    var onOpenTask: ((UUID) -> Void)?
    // Gate actions, keyed by runId. Reject carries the typed reason ("" if none).
    var onApprovePlan: ((UUID) -> Void)?
    var onRejectPlan: ((UUID, String) -> Void)?
    var onApproveReview: ((UUID) -> Void)?
    var onRejectReview: ((UUID, String) -> Void)?

    private var authorized = false

    private enum ActionID {
        static let approve = "gate.approve"
        static let reject = "gate.reject"
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let approve = UNNotificationAction(identifier: ActionID.approve,
                                           title: "Approve")
        let reject = UNTextInputNotificationAction(identifier: ActionID.reject,
                                                   title: "Reject…",
                                                   textInputButtonTitle: "Reject",
                                                   textInputPlaceholder: "Why? (optional)")
        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: TaskGate.plan.rawValue,
                                   actions: [approve, reject],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: TaskGate.review.rawValue,
                                   actions: [approve, reject],
                                   intentIdentifiers: []),
        ]
        center.setNotificationCategories(categories)

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(message: String, taskId: UUID) {
        deliver(message: message, userInfo: ["taskId": taskId.uuidString])
    }

    /// A gate notification: approve/reject act directly on the run.
    func postGate(_ gate: TaskGate, message: String, taskId: UUID, runId: UUID) {
        deliver(message: message,
                userInfo: ["taskId": taskId.uuidString,
                           "runId": runId.uuidString,
                           "gate": gate.rawValue],
                category: gate.rawValue)
    }

    private func deliver(message: String, userInfo: [String: Any], category: String? = nil) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Glance Tasks"
        content.body = message
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
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
        let info = response.notification.request.content.userInfo
        let taskId = (info["taskId"] as? String).flatMap(UUID.init(uuidString:))
        let runId = (info["runId"] as? String).flatMap(UUID.init(uuidString:))
        let gate = (info["gate"] as? String).flatMap(TaskGate.init(rawValue:))
        let reason = (response as? UNTextInputNotificationResponse)?.userText ?? ""

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch (response.actionIdentifier, gate, runId) {
            case (ActionID.approve, .plan, .some(let run)):
                self.onApprovePlan?(run)
            case (ActionID.reject, .plan, .some(let run)):
                self.onRejectPlan?(run, reason)
            case (ActionID.approve, .review, .some(let run)):
                self.onApproveReview?(run)
            case (ActionID.reject, .review, .some(let run)):
                self.onRejectReview?(run, reason)
            default:
                if let taskId { self.onOpenTask?(taskId) }
            }
        }
        completionHandler()
    }
}
