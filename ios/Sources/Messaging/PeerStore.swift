import Foundation

enum PeerStore {
    private static let peerLabelKey = "inbox_peer_label"
    private static let peerPublicKeyKey = "inbox_peer_public_key"
    private static let channelIdKey = "inbox_channel_id"

    static var peerLabel: String? {
        UserDefaults.standard.string(forKey: peerLabelKey)
    }

    static var peerPublicKeyBase64: String? {
        UserDefaults.standard.string(forKey: peerPublicKeyKey)
    }

    static var peerPublicKey: Data? {
        peerPublicKeyBase64.flatMap { Data(base64Encoded: $0) }
    }

    static var channelId: String? {
        UserDefaults.standard.string(forKey: channelIdKey)
    }

    static var peerConfigured: Bool {
        peerPublicKey != nil && channelId != nil
    }

    static func savePeer(label: String, publicKeyBase64: String, channelId: String) {
        UserDefaults.standard.set(label, forKey: peerLabelKey)
        UserDefaults.standard.set(publicKeyBase64, forKey: peerPublicKeyKey)
        UserDefaults.standard.set(channelId, forKey: channelIdKey)
    }

    static func parsePeerInput(_ input: String) -> (label: String, publicKeyBase64: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEd25519PublicKeyBase64(trimmed) {
            return ("agent", trimmed)
        }
        if let jsonData = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let publicKeyBase64 = parsed["public_key"] as? String,
           isEd25519PublicKeyBase64(publicKeyBase64) {
            return (parsed["label"] as? String ?? "agent", publicKeyBase64)
        }
        return nil
    }

    private static func isEd25519PublicKeyBase64(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }
}
