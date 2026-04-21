import CryptoKit
import Foundation
import Security
import APTerminalProtocol

public struct TrustedDeviceRecord: Codable, Equatable, Sendable {
    public static let trustLifetime: TimeInterval = APTerminalConfiguration.defaultTrustLifetime

    public var identity: DeviceIdentity
    public var publicKeyData: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var expiresAt: Date
    public var previewAccessModes: Set<HostConnectionMode>

    public init(
        identity: DeviceIdentity,
        publicKeyData: Data,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        expiresAt: Date,
        previewAccessModes: Set<HostConnectionMode> = []
    ) {
        self.identity = identity
        self.publicKeyData = publicKeyData
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
        self.previewAccessModes = previewAccessModes
    }

    public func publicKey() throws -> Curve25519.Signing.PublicKey {
        try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    public var hasPreviewAccess: Bool {
        previewAccessModes.isEmpty == false
    }

    public func allowsPreviewAccess(in mode: HostConnectionMode) -> Bool {
        previewAccessModes.contains(mode)
    }

    enum CodingKeys: String, CodingKey {
        case identity
        case publicKeyData
        case pairedAt
        case lastSeenAt
        case expiresAt
        case previewAccessModes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DeviceIdentity.self, forKey: .identity)
        publicKeyData = try container.decode(Data.self, forKey: .publicKeyData)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            ?? pairedAt.addingTimeInterval(Self.trustLifetime)
        previewAccessModes = try container.decodeIfPresent(Set<HostConnectionMode>.self, forKey: .previewAccessModes) ?? []
    }
}

public protocol TrustedDeviceStore: Sendable {
    func loadTrustedDevices() throws -> [TrustedDeviceRecord]
    func saveTrustedDevices(_ devices: [TrustedDeviceRecord]) throws
}

public enum TrustedDeviceStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidPayload
}

public final class InMemoryTrustedDeviceStore: TrustedDeviceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [TrustedDeviceRecord]

    public init(devices: [TrustedDeviceRecord] = []) {
        self.devices = devices
    }

    public func loadTrustedDevices() throws -> [TrustedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }

    public func saveTrustedDevices(_ devices: [TrustedDeviceRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.devices = devices
    }
}

public final class KeychainTrustedDeviceStore: TrustedDeviceStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = APTerminalConfiguration.trustedDevicesKeychainService,
        account: String = APTerminalConfiguration.defaultKeychainAccount
    ) {
        self.service = service
        self.account = account
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadTrustedDevices() throws -> [TrustedDeviceRecord] {
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
            guard let data = result as? Data else {
                throw TrustedDeviceStoreError.invalidPayload
            }

            return try decoder.decode([TrustedDeviceRecord].self, from: data)
        case errSecItemNotFound:
            return []
        default:
            throw TrustedDeviceStoreError.unexpectedStatus(status)
        }
    }

    public func saveTrustedDevices(_ devices: [TrustedDeviceRecord]) throws {
        let data = try encoder.encode(devices)

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
                throw TrustedDeviceStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw TrustedDeviceStoreError.unexpectedStatus(updateStatus)
        }
    }
}

public actor TrustedDeviceRegistry {
    private let store: TrustedDeviceStore
    private var devicesByID: [DeviceID: TrustedDeviceRecord]

    public init(store: TrustedDeviceStore) {
        self.store = store
        let devices = ((try? store.loadTrustedDevices()) ?? []).filter { $0.isExpired == false }
        self.devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.identity.id, $0) })
    }

    public func allDevices() -> [TrustedDeviceRecord] {
        purgeExpiredIfNeeded()
        return devicesByID.values.sorted { $0.identity.name.localizedCaseInsensitiveCompare($1.identity.name) == .orderedAscending }
    }

    public func isTrusted(deviceID: DeviceID) -> Bool {
        purgeExpiredIfNeeded()
        return devicesByID[deviceID] != nil
    }

    public func record(for deviceID: DeviceID) -> TrustedDeviceRecord? {
        purgeExpiredIfNeeded()
        return devicesByID[deviceID]
    }

    @discardableResult
    public func trust(identity: DeviceIdentity, publicKeyData: Data) throws -> TrustedDeviceRecord {
        let now = Date()
        let record = TrustedDeviceRecord(
            identity: identity,
            publicKeyData: publicKeyData,
            pairedAt: devicesByID[identity.id]?.pairedAt ?? now,
            lastSeenAt: now,
            expiresAt: now.addingTimeInterval(TrustedDeviceRecord.trustLifetime),
            previewAccessModes: devicesByID[identity.id]?.previewAccessModes ?? []
        )

        devicesByID[identity.id] = record
        try persist()
        return record
    }

    public func revoke(deviceID: DeviceID) throws {
        devicesByID.removeValue(forKey: deviceID)
        try persist()
    }

    public func markSeen(deviceID: DeviceID) throws {
        purgeExpiredIfNeeded()
        guard var record = devicesByID[deviceID] else {
            return
        }

        record.lastSeenAt = Date()
        devicesByID[deviceID] = record
        try persist()
    }

    @discardableResult
    public func setPreviewAccessModes(
        _ previewAccessModes: Set<HostConnectionMode>,
        for deviceID: DeviceID
    ) throws -> TrustedDeviceRecord? {
        purgeExpiredIfNeeded()
        guard var record = devicesByID[deviceID] else {
            return nil
        }

        record.previewAccessModes = previewAccessModes
        devicesByID[deviceID] = record
        try persist()
        return record
    }

    private func persist() throws {
        try store.saveTrustedDevices(Array(devicesByID.values))
    }

    private func purgeExpiredIfNeeded() {
        let expiredDeviceIDs = devicesByID.values
            .filter(\.isExpired)
            .map(\.identity.id)

        guard expiredDeviceIDs.isEmpty == false else {
            return
        }

        for deviceID in expiredDeviceIDs {
            devicesByID.removeValue(forKey: deviceID)
        }

        try? persist()
    }
}
