import Foundation

struct RelayMessage: Identifiable {
    let id: String
    let requestBlob: String
    let hasResponse: Bool
    let createdAt: Date
}

enum InboxRelayError: Error {
    case badUrl
    case requestFailed(Int, String)
    case invalidResponse
}

struct InboxRelayClient {
    static var baseUrl: String {
        UserDefaults.standard.string(forKey: "inbox_relay_url") ?? "https://actionhub.app"
    }

    func fetchMessages(channelId: String) async throws -> [RelayMessage] {
        guard let url = URL(string: "\(Self.baseUrl)/messages?channel=\(channelId)") else { throw InboxRelayError.badUrl }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.ensureSuccess(response, data)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InboxRelayError.invalidResponse
        }
        return records.compactMap { record in
            guard let id = record["id"] as? String,
                  let requestBlob = record["request_blob"] as? String,
                  let createdAtMilliseconds = record["created_at"] as? Double else { return nil }
            let responseBlob = record["response_blob"] as? String
            return RelayMessage(
                id: id,
                requestBlob: requestBlob,
                hasResponse: responseBlob != nil && !responseBlob!.isEmpty,
                createdAt: Date(timeIntervalSince1970: createdAtMilliseconds / 1000)
            )
        }
    }

    func postResponse(messageId: String, responseBlob: String) async throws {
        guard let url = URL(string: "\(Self.baseUrl)/messages/\(messageId)") else { throw InboxRelayError.badUrl }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["response_blob": responseBlob])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureSuccess(response, data)
    }

    private static func ensureSuccess(_ response: URLResponse, _ data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw InboxRelayError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw InboxRelayError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
