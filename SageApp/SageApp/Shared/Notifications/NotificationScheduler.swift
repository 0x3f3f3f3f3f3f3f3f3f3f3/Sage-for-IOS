import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    func requestAuthorizationIfNeeded() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func scheduleReminder(for task: TaskDTO) async {
        await requestAuthorizationIfNeeded()
        guard let reminderAt = task.reminderAt.flatMap(ISO8601DateFormatter().date) else {
            await cancelReminder(for: task.id)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = task.description ?? String(localized: "notification.task.reminder")
        content.sound = .default

        let triggerDate = Calendar.current.dateComponents(in: .current, from: reminderAt)
        let request = UNNotificationRequest(
            identifier: reminderIdentifier(for: task.id),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelReminder(for taskID: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(for: taskID)])
    }

    private func reminderIdentifier(for taskID: String) -> String {
        "sage.task.reminder.\(taskID)"
    }
}
