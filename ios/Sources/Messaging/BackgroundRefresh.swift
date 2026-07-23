import BackgroundTasks
import Foundation
import UserNotifications

enum BackgroundRefresh {
    static let taskIdentifier = "li.taurusag.actionhub.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let probeTask = Task {
            let freshPendingCount = await freshPendingQuestionCount()
            if freshPendingCount > 0 {
                await notifyPending(count: freshPendingCount)
            }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { probeTask.cancel() }
    }

    static func freshPendingQuestionCount() async -> Int {
        guard let channelId = PeerStore.channelId else { return 0 }
        guard let messages = try? await InboxRelayClient().fetchMessages(channelId: channelId) else { return 0 }
        let freshPending = messages.filter { message in
            !message.hasResponse
                && AnsweredStore.answeredValue(messageId: message.id) == nil
                && !AnsweredStore.alreadyNotified(messageId: message.id)
        }
        AnsweredStore.markNotified(messageIds: freshPending.map(\.id))
        return freshPending.count
    }

    static func notifyPending(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "New message"
        content.body = count == 1 ? "A message is waiting in your inbox" : "\(count) messages are waiting in your inbox"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
