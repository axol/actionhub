import Foundation
import LocalAuthentication
import Security

enum SecureMessagingIdentityError: Error {
    case accessControlCreationFailed
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case identityMissing
    case randomGenerationFailed
}

enum SecureMessagingIdentityStore {
    private static let seedService = "li.taurusag.actionhub.identity.seed"
    private static let publicKeyService = "li.taurusag.actionhub.identity.public"
    private static let account = "main"

    static func identityExists() -> Bool {
        publicKey() != nil
    }

    static func publicKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: publicKeyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func createIdentity() throws -> Data {
        var seed = Data(count: 32)
        let randomStatus = seed.withUnsafeMutableBytes { seedPointer in
            SecRandomCopyBytes(kSecRandomDefault, 32, seedPointer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw SecureMessagingIdentityError.randomGenerationFailed }
        let keyPair = try SecureMessagingCrypto.keyPair(seed: seed)

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessControlError
        ) else {
            throw SecureMessagingIdentityError.accessControlCreationFailed
        }

        let seedAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seedService,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: accessControl,
            kSecValueData as String: seed
        ]
        let seedStatus = SecItemAdd(seedAttributes as CFDictionary, nil)
        guard seedStatus == errSecSuccess else { throw SecureMessagingIdentityError.keychainWriteFailed(seedStatus) }

        let publicKeyAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: publicKeyService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: keyPair.ed25519PublicKey
        ]
        let publicKeyStatus = SecItemAdd(publicKeyAttributes as CFDictionary, nil)
        guard publicKeyStatus == errSecSuccess else { throw SecureMessagingIdentityError.keychainWriteFailed(publicKeyStatus) }

        return keyPair.ed25519PublicKey
    }

    static func loadKeyPair(authenticationReason: String, authenticationContext: LAContext = LAContext()) throws -> SecureMessagingKeyPair {
        authenticationContext.localizedReason = authenticationReason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seedService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let seed = result as? Data else {
            if status == errSecItemNotFound { throw SecureMessagingIdentityError.identityMissing }
            throw SecureMessagingIdentityError.keychainReadFailed(status)
        }
        return try SecureMessagingCrypto.keyPair(seed: seed)
    }
}
