import Foundation

enum SecureMessageEnvelope {
    static func seal(payloadJson: String, senderKeyPair: SecureMessagingKeyPair, recipientEd25519PublicKey: Data) throws -> String {
        let payloadData = Data(payloadJson.utf8)
        let signature = try SecureMessagingCrypto.signature(message: payloadData, ed25519SecretKey: senderKeyPair.ed25519SecretKey)
        let envelope: [String: Any] = [
            "version": 1,
            "signature": signature.base64EncodedString(),
            "sender_public_key": senderKeyPair.ed25519PublicKey.base64EncodedString(),
            "payload": payloadJson
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        let sealed = try SecureMessagingCrypto.sealedBoxEncrypt(plaintext: envelopeData, recipientEd25519PublicKey: recipientEd25519PublicKey)
        return sealed.base64EncodedString()
    }

    static func open(blob: String, recipientKeyPair: SecureMessagingKeyPair, expectedSenderEd25519PublicKey: Data) throws -> String {
        guard let ciphertext = Data(base64Encoded: blob) else { throw SecureMessagingCryptoError.invalidEnvelope }
        let envelopeData = try SecureMessagingCrypto.sealedBoxDecrypt(ciphertext: ciphertext, recipientKeyPair: recipientKeyPair)
        guard let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let payloadJson = envelope["payload"] as? String,
              let signatureBase64 = envelope["signature"] as? String,
              let senderPublicKeyBase64 = envelope["sender_public_key"] as? String,
              let signature = Data(base64Encoded: signatureBase64) else {
            throw SecureMessagingCryptoError.invalidEnvelope
        }
        guard senderPublicKeyBase64 == expectedSenderEd25519PublicKey.base64EncodedString() else {
            throw SecureMessagingCryptoError.senderMismatch
        }
        guard SecureMessagingCrypto.isValidSignature(signature, message: Data(payloadJson.utf8), ed25519PublicKey: expectedSenderEd25519PublicKey) else {
            throw SecureMessagingCryptoError.signatureInvalid
        }
        return payloadJson
    }
}
