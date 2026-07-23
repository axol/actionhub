import Foundation
import LocalAuthentication
import Security

enum SecureEnclaveSignerError: Error {
    case accessControlCreationFailed
    case keyCreationFailed(String)
    case keyMissing
    case publicKeyExportFailed
    case signingFailed(String)
}

enum SecureEnclaveSigner {
    private static let keyTag = "li.taurusag.actionhub.biometric.p256"

    static var keyExists: Bool {
        (try? privateKey(authenticationContext: nil)) != nil
    }

    static func publicKeyBase64() -> String? {
        try? publicKeyData().base64EncodedString()
    }

    @discardableResult
    static func createKey() throws -> Data {
        if keyExists { return try publicKeyData() }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessControlError
        ) else {
            throw SecureEnclaveSignerError.accessControlCreationFailed
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(keyTag.utf8),
                kSecAttrAccessControl as String: accessControl
            ]
        ]
        var creationError: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) != nil else {
            let message = creationError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveSignerError.keyCreationFailed(message)
        }
        return try publicKeyData()
    }

    static func sign(message: Data, authenticationContext: LAContext) throws -> Data {
        let key = try privateKey(authenticationContext: authenticationContext)
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &signingError) else {
            let message = signingError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveSignerError.signingFailed(message)
        }
        return signature as Data
    }

    private static func publicKeyData() throws -> Data {
        let key = try privateKey(authenticationContext: nil)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            throw SecureEnclaveSignerError.publicKeyExportFailed
        }
        return publicKeyData as Data
    }

    private static func privateKey(authenticationContext: LAContext?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            throw SecureEnclaveSignerError.keyMissing
        }
        return result as! SecKey
    }
}
