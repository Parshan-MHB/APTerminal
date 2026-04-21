import CryptoKit
import Foundation
import Security
import APTerminalProtocol

public protocol SigningKeyStore: Sendable {
    func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey
}

public enum SigningKeyStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidPayload
}

public final class InMemorySigningKeyStore: SigningKeyStore, @unchecked Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        privateKey
    }
}

public final class KeychainSigningKeyStore: SigningKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = APTerminalConfiguration.signingKeyKeychainService,
        account: String = APTerminalConfiguration.defaultKeychainAccount
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try loadData() {
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw SigningKeyStoreError.invalidPayload
            }
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        try saveData(privateKey.rawRepresentation)
        return privateKey
    }

    private func loadData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func saveData(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SigningKeyStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SigningKeyStoreError.unexpectedStatus(updateStatus)
        }
    }
}
