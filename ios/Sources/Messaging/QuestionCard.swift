import Foundation

struct QuestionButton: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { value }
}

struct QuestionCard: Identifiable, Equatable {
    let id: String
    let title: String
    let bodyContentType: String
    let bodyContent: String
    let buttons: [QuestionButton]
    let createdAt: Date
    let rawPayloadJson: String
    var answeredValue: String?

    static func parse(messageId: String, payloadJson: String, createdAt: Date) -> QuestionCard? {
        guard let payloadData = payloadJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["envelope_type"] as? String == "request" else { return nil }

        let title = payload["title"] as? String ?? "Untitled"
        var bodyContentType = "txt"
        var bodyContent = payload["message"] as? String ?? ""
        if let body = payload["body"] as? [String: Any],
           let contentType = body["content_type"] as? String,
           let content = body["content"] as? String {
            bodyContentType = contentType
            bodyContent = content
        }
        let buttons = (payload["buttons"] as? [[String: Any]] ?? []).compactMap { buttonRecord -> QuestionButton? in
            guard let label = buttonRecord["label"] as? String, let value = buttonRecord["value"] as? String else { return nil }
            return QuestionButton(label: label, value: value)
        }
        return QuestionCard(
            id: messageId,
            title: title,
            bodyContentType: bodyContentType,
            bodyContent: bodyContent,
            buttons: buttons,
            createdAt: createdAt,
            rawPayloadJson: payloadJson,
            answeredValue: nil
        )
    }
}
