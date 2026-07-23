import Clibsodium
import CryptoKit
import Foundation

enum SecureMessagingCryptoError: Error {
    case sodiumInitializationFailed
    case keyDerivationFailed
    case signingFailed
    case signatureInvalid
    case sealFailed
    case openFailed
    case invalidEnvelope
    case senderMismatch
}

struct SecureMessagingKeyPair {
    let ed25519PublicKey: Data
    let ed25519SecretKey: Data
}

enum SecureMessagingCrypto {
    static func ensureSodiumReady() throws {
        guard sodium_init() >= 0 else { throw SecureMessagingCryptoError.sodiumInitializationFailed }
    }

    static func keyPair(seed: Data) throws -> SecureMessagingKeyPair {
        try ensureSodiumReady()
        var publicKey = [UInt8](repeating: 0, count: Int(crypto_sign_publickeybytes()))
        var secretKey = [UInt8](repeating: 0, count: Int(crypto_sign_secretkeybytes()))
        let seedBytes = [UInt8](seed)
        guard crypto_sign_seed_keypair(&publicKey, &secretKey, seedBytes) == 0 else {
            throw SecureMessagingCryptoError.keyDerivationFailed
        }
        return SecureMessagingKeyPair(ed25519PublicKey: Data(publicKey), ed25519SecretKey: Data(secretKey))
    }

    static func x25519PublicKey(fromEd25519PublicKey ed25519PublicKey: Data) throws -> Data {
        try ensureSodiumReady()
        var converted = [UInt8](repeating: 0, count: Int(crypto_scalarmult_bytes()))
        guard crypto_sign_ed25519_pk_to_curve25519(&converted, [UInt8](ed25519PublicKey)) == 0 else {
            throw SecureMessagingCryptoError.keyDerivationFailed
        }
        return Data(converted)
    }

    static func x25519SecretKey(fromEd25519SecretKey ed25519SecretKey: Data) throws -> Data {
        try ensureSodiumReady()
        var converted = [UInt8](repeating: 0, count: Int(crypto_scalarmult_scalarbytes()))
        guard crypto_sign_ed25519_sk_to_curve25519(&converted, [UInt8](ed25519SecretKey)) == 0 else {
            throw SecureMessagingCryptoError.keyDerivationFailed
        }
        return Data(converted)
    }

    static func sharedSecret(ownEd25519SecretKey: Data, peerEd25519PublicKey: Data) throws -> Data {
        let ownX25519SecretKey = try x25519SecretKey(fromEd25519SecretKey: ownEd25519SecretKey)
        let peerX25519PublicKey = try x25519PublicKey(fromEd25519PublicKey: peerEd25519PublicKey)
        var secret = [UInt8](repeating: 0, count: Int(crypto_scalarmult_bytes()))
        guard crypto_scalarmult(&secret, [UInt8](ownX25519SecretKey), [UInt8](peerX25519PublicKey)) == 0 else {
            throw SecureMessagingCryptoError.keyDerivationFailed
        }
        return Data(secret)
    }

    static func channelId(ownEd25519SecretKey: Data, peerEd25519PublicKey: Data, channelName: String = "canvas") throws -> String {
        let secret = try sharedSecret(ownEd25519SecretKey: ownEd25519SecretKey, peerEd25519PublicKey: peerEd25519PublicKey)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: Data(channelName.utf8), using: SymmetricKey(data: secret))
        return Data(authenticationCode).map { String(format: "%02x", $0) }.joined()
    }

    static func signature(message: Data, ed25519SecretKey: Data) throws -> Data {
        try ensureSodiumReady()
        var signatureBytes = [UInt8](repeating: 0, count: Int(crypto_sign_bytes()))
        var signatureLength: UInt64 = 0
        guard crypto_sign_detached(&signatureBytes, &signatureLength, [UInt8](message), UInt64(message.count), [UInt8](ed25519SecretKey)) == 0 else {
            throw SecureMessagingCryptoError.signingFailed
        }
        return Data(signatureBytes.prefix(Int(signatureLength)))
    }

    static func isValidSignature(_ signature: Data, message: Data, ed25519PublicKey: Data) -> Bool {
        guard (try? ensureSodiumReady()) != nil else { return false }
        return crypto_sign_verify_detached([UInt8](signature), [UInt8](message), UInt64(message.count), [UInt8](ed25519PublicKey)) == 0
    }

    static func sealedBoxEncrypt(plaintext: Data, recipientEd25519PublicKey: Data) throws -> Data {
        let recipientX25519PublicKey = try x25519PublicKey(fromEd25519PublicKey: recipientEd25519PublicKey)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + Int(crypto_box_sealbytes()))
        guard crypto_box_seal(&ciphertext, [UInt8](plaintext), UInt64(plaintext.count), [UInt8](recipientX25519PublicKey)) == 0 else {
            throw SecureMessagingCryptoError.sealFailed
        }
        return Data(ciphertext)
    }

    static func sealedBoxDecrypt(ciphertext: Data, recipientKeyPair: SecureMessagingKeyPair) throws -> Data {
        let recipientX25519PublicKey = try x25519PublicKey(fromEd25519PublicKey: recipientKeyPair.ed25519PublicKey)
        let recipientX25519SecretKey = try x25519SecretKey(fromEd25519SecretKey: recipientKeyPair.ed25519SecretKey)
        let sealOverhead = Int(crypto_box_sealbytes())
        guard ciphertext.count > sealOverhead else { throw SecureMessagingCryptoError.openFailed }
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - sealOverhead)
        guard crypto_box_seal_open(&plaintext, [UInt8](ciphertext), UInt64(ciphertext.count), [UInt8](recipientX25519PublicKey), [UInt8](recipientX25519SecretKey)) == 0 else {
            throw SecureMessagingCryptoError.openFailed
        }
        return Data(plaintext)
    }
}
