import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class InboxStore: ObservableObject {
    enum EnrollmentPhase {
        case needsIdentity
        case needsPeer
        case ready
    }

    @Published var enrollmentPhase: EnrollmentPhase
    @Published var cards: [QuestionCard] = []
    @Published var unlocked = false
    @Published var refreshing = false
    @Published var statusMessage: String?
    @Published var ownPublicKeyBase64: String?
    @Published var biometricPublicKeyBase64: String? = SecureEnclaveSigner.publicKeyBase64()

    private var cachedKeyPair: SecureMessagingKeyPair?
    private let relayClient = InboxRelayClient()

    init() {
        enrollmentPhase = Self.currentPhase()
        ownPublicKeyBase64 = SecureMessagingIdentityStore.publicKey()?.base64EncodedString()
    }

    static func currentPhase() -> EnrollmentPhase {
        guard SecureMessagingIdentityStore.identityExists() else { return .needsIdentity }
        guard PeerStore.peerConfigured else { return .needsPeer }
        return .ready
    }

    func createIdentity() {
        do {
            let publicKey = try SecureMessagingIdentityStore.createIdentity()
            ownPublicKeyBase64 = publicKey.base64EncodedString()
            enrollmentPhase = Self.currentPhase()
            statusMessage = nil
        } catch {
            statusMessage = "Identity creation failed: \(error)"
        }
    }

    func savePeer(input: String) async {
        guard let parsedPeer = PeerStore.parsePeerInput(input) else {
            statusMessage = "Unrecognized key format"
            return
        }
        do {
            let keyPair = try await loadKeyPair(reason: "Derive the shared channel")
            let peerPublicKey = Data(base64Encoded: parsedPeer.publicKeyBase64)!
            let channelId = try SecureMessagingCrypto.channelId(ownEd25519SecretKey: keyPair.ed25519SecretKey, peerEd25519PublicKey: peerPublicKey)
            PeerStore.savePeer(label: parsedPeer.label, publicKeyBase64: parsedPeer.publicKeyBase64, channelId: channelId)
            cachedKeyPair = keyPair
            unlocked = true
            enrollmentPhase = Self.currentPhase()
            statusMessage = nil
            await refresh()
        } catch {
            statusMessage = "Pairing failed: \(error)"
        }
    }

    func unlock() async {
        guard enrollmentPhase == .ready, !unlocked else { return }
        do {
            cachedKeyPair = try await loadKeyPair(reason: "Unlock your inbox")
            unlocked = true
            statusMessage = nil
            await refresh()
        } catch {
            statusMessage = "Unlock failed"
        }
    }

    func refresh() async {
        guard unlocked, let keyPair = cachedKeyPair,
              let channelId = PeerStore.channelId,
              let peerPublicKey = PeerStore.peerPublicKey else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let messages = try await relayClient.fetchMessages(channelId: channelId)
            var parsedCards: [QuestionCard] = []
            for message in messages {
                guard let payloadJson = try? SecureMessageEnvelope.open(
                    blob: message.requestBlob,
                    recipientKeyPair: keyPair,
                    expectedSenderEd25519PublicKey: peerPublicKey
                ) else { continue }
                guard var card = QuestionCard.parse(messageId: message.id, payloadJson: payloadJson, createdAt: message.createdAt) else { continue }
                if message.hasResponse {
                    card.answeredValue = AnsweredStore.answeredValue(messageId: message.id) ?? "answered"
                }
                parsedCards.append(card)
            }
            AnsweredStore.markNotified(messageIds: parsedCards.map(\.id))
            cards = parsedCards.sorted { first, second in
                if (first.answeredValue == nil) != (second.answeredValue == nil) {
                    return first.answeredValue == nil
                }
                return first.createdAt > second.createdAt
            }
            statusMessage = nil
        } catch {
            statusMessage = "Refresh failed: \(error)"
        }
    }

    func submitAnswer(card: QuestionCard, button: QuestionButton, note: String) async {
        guard let peerPublicKey = PeerStore.peerPublicKey else { return }
        do {
            let signedNote: String? = note.isEmpty ? nil : note
            let authenticationContext = LAContext()
            let keyPair = try await loadKeyPair(reason: "Sign answer: \(button.label)", authenticationContext: authenticationContext)
            let timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
            var biometricSignatureBase64: String?
            if SecureEnclaveSigner.keyExists {
                let biometricMessage = ResponsePayloadBuilder.biometricSignedMessage(
                    requestId: card.id,
                    buttonValue: button.value,
                    timestampMilliseconds: timestampMilliseconds,
                    note: signedNote
                )
                biometricSignatureBase64 = try await Task.detached {
                    try SecureEnclaveSigner.sign(message: biometricMessage, authenticationContext: authenticationContext)
                }.value.base64EncodedString()
            }
            let responsePayloadJson = ResponsePayloadBuilder.responsePayloadJson(
                requestId: card.id,
                rawRequestPayloadJson: card.rawPayloadJson,
                buttonLabel: button.label,
                buttonValue: button.value,
                timestampMilliseconds: timestampMilliseconds,
                note: signedNote,
                biometricSignatureBase64: biometricSignatureBase64
            )
            let responseBlob = try SecureMessageEnvelope.seal(
                payloadJson: responsePayloadJson,
                senderKeyPair: keyPair,
                recipientEd25519PublicKey: peerPublicKey
            )
            try await relayClient.postResponse(messageId: card.id, responseBlob: responseBlob)
            AnsweredStore.record(messageId: card.id, value: button.value)
            statusMessage = nil
            await refresh()
        } catch {
            statusMessage = "Answer failed: \(error)"
        }
    }

    func createBiometricKey() {
        do {
            biometricPublicKeyBase64 = try SecureEnclaveSigner.createKey().base64EncodedString()
            statusMessage = nil
        } catch {
            statusMessage = "Biometric key creation failed: \(error)"
        }
    }

    private func loadKeyPair(reason: String, authenticationContext: LAContext = LAContext()) async throws -> SecureMessagingKeyPair {
        try await Task.detached {
            try SecureMessagingIdentityStore.loadKeyPair(authenticationReason: reason, authenticationContext: authenticationContext)
        }.value
    }
}
