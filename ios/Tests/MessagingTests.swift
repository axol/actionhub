import CryptoKit
import XCTest
@testable import ActionHub

final class MessagingTests: XCTestCase {
    struct Vectors: Decodable {
        let hmac_key: String
        let phone_seed: String
        let phone_public_key: String
        let agent_seed: String
        let agent_public_key: String
        let channel_id: String
        let request_id: String
        let request_payload_json: String
        let request_blob: String
        let signature_probe_message: String
        let phone_probe_signature: String
        let biometric_public_key: String
        let biometric_message: String
        let biometric_signature: String
    }

    private var vectors: Vectors!
    private var phoneKeyPair: SecureMessagingKeyPair!
    private var agentKeyPair: SecureMessagingKeyPair!

    override func setUpWithError() throws {
        let fixtureUrl = try XCTUnwrap(Bundle(for: MessagingTests.self).url(forResource: "vectors", withExtension: "json"))
        vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: fixtureUrl))
        phoneKeyPair = try SecureMessagingCrypto.keyPair(seed: Data(base64Encoded: vectors.phone_seed)!)
        agentKeyPair = try SecureMessagingCrypto.keyPair(seed: Data(base64Encoded: vectors.agent_seed)!)
    }

    func testKeyPairDerivationMatchesRuby() {
        XCTAssertEqual(phoneKeyPair.ed25519PublicKey.base64EncodedString(), vectors.phone_public_key)
        XCTAssertEqual(agentKeyPair.ed25519PublicKey.base64EncodedString(), vectors.agent_public_key)
    }

    func testChannelIdMatchesRuby() throws {
        let channelId = try SecureMessagingCrypto.channelId(
            ownEd25519SecretKey: phoneKeyPair.ed25519SecretKey,
            peerEd25519PublicKey: Data(base64Encoded: vectors.agent_public_key)!
        )
        XCTAssertEqual(channelId, vectors.channel_id)
    }

    func testProbeSignatureMatchesRuby() throws {
        let signature = try SecureMessagingCrypto.signature(
            message: Data(vectors.signature_probe_message.utf8),
            ed25519SecretKey: phoneKeyPair.ed25519SecretKey
        )
        XCTAssertEqual(signature.base64EncodedString(), vectors.phone_probe_signature)
    }

    func testOpenRubyRequestEnvelope() throws {
        let payloadJson = try SecureMessageEnvelope.open(
            blob: vectors.request_blob,
            recipientKeyPair: phoneKeyPair,
            expectedSenderEd25519PublicKey: Data(base64Encoded: vectors.agent_public_key)!
        )
        XCTAssertEqual(payloadJson, vectors.request_payload_json)
    }

    func testOpenRejectsUnexpectedSender() {
        XCTAssertThrowsError(try SecureMessageEnvelope.open(
            blob: vectors.request_blob,
            recipientKeyPair: phoneKeyPair,
            expectedSenderEd25519PublicKey: phoneKeyPair.ed25519PublicKey
        )) { thrownError in
            XCTAssertEqual(thrownError as? SecureMessagingCryptoError, .senderMismatch)
        }
    }

    func testQuestionCardParsing() throws {
        let card = try XCTUnwrap(QuestionCard.parse(messageId: vectors.request_id, payloadJson: vectors.request_payload_json, createdAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(card.title, "Ship the relay?")
        XCTAssertEqual(card.bodyContentType, "html")
        XCTAssertEqual(card.buttons.map(\.value), ["ship", "hold"])
        XCTAssertEqual(card.rawPayloadJson, vectors.request_payload_json)
    }

    func testResponsePayloadSplicesRawRequestBytes() throws {
        let responseJson = ResponsePayloadBuilder.responsePayloadJson(
            requestId: vectors.request_id,
            rawRequestPayloadJson: vectors.request_payload_json,
            buttonLabel: "Ship it",
            buttonValue: "ship",
            timestampMilliseconds: 1702500000000,
            note: "with \"quotes\" and\nnewline ✅"
        )
        XCTAssertTrue(responseJson.contains("\"request_payload\":\(vectors.request_payload_json)"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(responseJson.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["envelope_type"] as? String, "response")
        XCTAssertEqual(parsed["type"] as? String, "action_response")
        XCTAssertEqual(parsed["request_id"] as? String, vectors.request_id)
        XCTAssertEqual(parsed["timestamp"] as? Int64, 1702500000000)
        XCTAssertEqual((parsed["utterances"] as? [String])?.first, "with \"quotes\" and\nnewline ✅")
        let responseSection = try XCTUnwrap(parsed["response"] as? [String: Any])
        let buttonSection = try XCTUnwrap(responseSection["button"] as? [String: Any])
        XCTAssertEqual(buttonSection["label"] as? String, "Ship it")
        XCTAssertEqual(buttonSection["value"] as? String, "ship")
        let echoedRequestPayload = try XCTUnwrap(parsed["request_payload"] as? [String: Any])
        XCTAssertEqual(echoedRequestPayload["envelope_type"] as? String, "request")
        XCTAssertEqual(echoedRequestPayload["nonce"] as? String, "deadbeefdeadbeef")
    }

    func testResponseEnvelopeRoundTrip() throws {
        let responseJson = ResponsePayloadBuilder.responsePayloadJson(
            requestId: vectors.request_id,
            rawRequestPayloadJson: vectors.request_payload_json,
            buttonLabel: "Ship it",
            buttonValue: "ship",
            timestampMilliseconds: 1702500000000,
            note: nil
        )
        let responseBlob = try SecureMessageEnvelope.seal(
            payloadJson: responseJson,
            senderKeyPair: phoneKeyPair,
            recipientEd25519PublicKey: agentKeyPair.ed25519PublicKey
        )
        let openedJson = try SecureMessageEnvelope.open(
            blob: responseBlob,
            recipientKeyPair: agentKeyPair,
            expectedSenderEd25519PublicKey: phoneKeyPair.ed25519PublicKey
        )
        XCTAssertEqual(openedJson, responseJson)
    }

    func testTamperedSignatureRejected() throws {
        let responseBlob = try SecureMessageEnvelope.seal(
            payloadJson: "{\"envelope_type\":\"response\"}",
            senderKeyPair: phoneKeyPair,
            recipientEd25519PublicKey: agentKeyPair.ed25519PublicKey
        )
        XCTAssertThrowsError(try SecureMessageEnvelope.open(
            blob: responseBlob,
            recipientKeyPair: agentKeyPair,
            expectedSenderEd25519PublicKey: agentKeyPair.ed25519PublicKey
        ))
    }

    func testBiometricMessageBytesMatchRuby() {
        let message = ResponsePayloadBuilder.biometricSignedMessage(
            requestId: vectors.request_id,
            buttonValue: "ship",
            timestampMilliseconds: 1702500000000,
            note: nil
        )
        XCTAssertEqual(String(data: message, encoding: .utf8), vectors.biometric_message)
    }

    func testBiometricRubySignatureVerifies() throws {
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: vectors.biometric_public_key)!)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: vectors.biometric_signature)!)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(vectors.biometric_message.utf8)))
    }

    func testBiometricSoftwareSignatureRoundTrip() throws {
        let privateKey = P256.Signing.PrivateKey()
        let message = ResponsePayloadBuilder.biometricSignedMessage(
            requestId: vectors.request_id,
            buttonValue: "hold",
            timestampMilliseconds: 1702500000001,
            note: "why"
        )
        let signature = try privateKey.signature(for: message)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: message))
    }

    func testResponsePayloadIncludesBiometricSignature() throws {
        let responseJson = ResponsePayloadBuilder.responsePayloadJson(
            requestId: vectors.request_id,
            rawRequestPayloadJson: vectors.request_payload_json,
            buttonLabel: "Ship it",
            buttonValue: "ship",
            timestampMilliseconds: 1702500000000,
            note: nil,
            biometricSignatureBase64: "QUJD"
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(responseJson.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["biometric_signature"] as? String, "QUJD")
        XCTAssertEqual(parsed["envelope_type"] as? String, "response")
    }

    func testJsonEscapedString() {
        XCTAssertEqual(ResponsePayloadBuilder.jsonEscapedString("plain"), "\"plain\"")
        XCTAssertEqual(ResponsePayloadBuilder.jsonEscapedString("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"")
        XCTAssertEqual(ResponsePayloadBuilder.jsonEscapedString("\u{01}"), "\"\\u0001\"")
        XCTAssertEqual(ResponsePayloadBuilder.jsonEscapedString("emoji 🚀 stays"), "\"emoji 🚀 stays\"")
    }
}

extension SecureMessagingCryptoError: Equatable {}
