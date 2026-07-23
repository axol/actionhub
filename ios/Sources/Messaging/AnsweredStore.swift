import Foundation

enum AnsweredStore {
    private static let answersKey = "inbox_answers"
    private static let notifiedIdsKey = "inbox_notified_ids"

    static func answeredValue(messageId: String) -> String? {
        answers[messageId]
    }

    static func record(messageId: String, value: String) {
        var updated = answers
        updated[messageId] = value
        UserDefaults.standard.set(updated, forKey: answersKey)
    }

    static func alreadyNotified(messageId: String) -> Bool {
        notifiedIds.contains(messageId)
    }

    static func markNotified(messageIds: [String]) {
        let updated = notifiedIds.union(messageIds)
        UserDefaults.standard.set(Array(updated), forKey: notifiedIdsKey)
    }

    private static var answers: [String: String] {
        UserDefaults.standard.dictionary(forKey: answersKey) as? [String: String] ?? [:]
    }

    private static var notifiedIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: notifiedIdsKey) ?? [])
    }
}
