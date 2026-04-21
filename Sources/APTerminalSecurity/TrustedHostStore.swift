import Foundation
import APTerminalProtocol

public struct TrustedHostRecord: Codable, Equatable, Sendable {
    public static let trustLifetime: TimeInterval = APTerminalConfiguration.defaultTrustLifetime

    public var host: DeviceIdentity
    public var hostAddress: String
    public var port: UInt16
    public var connectionMode: HostConnectionMode
    public var endpointKind: HostEndpointKind
    public var publicKeyData: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var expiresAt: Date

    public init(
        host: DeviceIdentity,
        hostAddress: String,
        port: UInt16,
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind,
        publicKeyData: Data,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        expiresAt: Date
    ) {
        self.host = host
        self.hostAddress = hostAddress
        self.port = port
        self.connectionMode = connectionMode
        self.endpointKind = endpointKind
        self.publicKeyData = publicKeyData
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    enum CodingKeys: String, CodingKey {
        case host
        case hostAddress
        case port
        case connectionMode
        case endpointKind
        case publicKeyData
        case pairedAt
        case lastSeenAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(DeviceIdentity.self, forKey: .host)
        hostAddress = try container.decode(String.self, forKey: .hostAddress)
        port = try container.decode(UInt16.self, forKey: .port)
        connectionMode = try container.decodeIfPresent(HostConnectionMode.self, forKey: .connectionMode) ?? .lan
        endpointKind = try container.decodeIfPresent(HostEndpointKind.self, forKey: .endpointKind) ?? .localNetwork
        publicKeyData = try container.decode(Data.self, forKey: .publicKeyData)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            ?? pairedAt.addingTimeInterval(Self.trustLifetime)
    }
}

public protocol TrustedHostStore: Sendable {
    func loadTrustedHosts() throws -> [TrustedHostRecord]
    func saveTrustedHosts(_ hosts: [TrustedHostRecord]) throws
}

public final class FileTrustedHostStore: TrustedHostStore, @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL(appName: String = APTerminalConfiguration.appName) -> URL {
        APTerminalStoragePaths.trustedHostsFileURL(appName: appName)
    }

    public func loadTrustedHosts() throws -> [TrustedHostRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([TrustedHostRecord].self, from: data)
    }

    public func saveTrustedHosts(_ hosts: [TrustedHostRecord]) throws {
        let data = try encoder.encode(hosts)
        try ProtectedFileIO.write(data, to: fileURL)
    }
}

public final class InMemoryTrustedHostStore: TrustedHostStore, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [TrustedHostRecord]

    public init(hosts: [TrustedHostRecord] = []) {
        self.hosts = hosts
    }

    public func loadTrustedHosts() throws -> [TrustedHostRecord] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    public func saveTrustedHosts(_ hosts: [TrustedHostRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.hosts = hosts
    }
}

public actor TrustedHostRegistry {
    private let store: TrustedHostStore
    private var hostsByID: [DeviceID: TrustedHostRecord]

    public init(store: TrustedHostStore) {
        self.store = store
        let hosts = ((try? store.loadTrustedHosts()) ?? []).filter { $0.isExpired == false }
        self.hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.host.id, $0) })
    }

    public func allHosts() -> [TrustedHostRecord] {
        purgeExpiredIfNeeded()
        return hostsByID.values.sorted { $0.host.name.localizedCaseInsensitiveCompare($1.host.name) == .orderedAscending }
    }

    public func record(for hostID: DeviceID) -> TrustedHostRecord? {
        purgeExpiredIfNeeded()
        return hostsByID[hostID]
    }

    public func trust(
        host: DeviceIdentity,
        hostAddress: String,
        port: UInt16,
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind,
        publicKeyData: Data
    ) throws {
        let now = Date()
        let record = TrustedHostRecord(
            host: host,
            hostAddress: hostAddress,
            port: port,
            connectionMode: connectionMode,
            endpointKind: endpointKind,
            publicKeyData: publicKeyData,
            pairedAt: hostsByID[host.id]?.pairedAt ?? now,
            lastSeenAt: now,
            expiresAt: now.addingTimeInterval(TrustedHostRecord.trustLifetime)
        )
        hostsByID[host.id] = record
        try persist()
    }

    public func markSeen(
        hostID: DeviceID,
        hostAddress: String,
        port: UInt16,
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind
    ) throws {
        purgeExpiredIfNeeded()
        guard var record = hostsByID[hostID] else { return }
        record.lastSeenAt = Date()
        record.hostAddress = hostAddress
        record.port = port
        record.connectionMode = connectionMode
        record.endpointKind = endpointKind
        hostsByID[hostID] = record
        try persist()
    }

    public func revoke(hostID: DeviceID) throws {
        hostsByID.removeValue(forKey: hostID)
        try persist()
    }

    private func persist() throws {
        try store.saveTrustedHosts(Array(hostsByID.values))
    }

    private func purgeExpiredIfNeeded() {
        let expiredHostIDs = hostsByID.values
            .filter(\.isExpired)
            .map(\.host.id)

        guard expiredHostIDs.isEmpty == false else {
            return
        }

        for hostID in expiredHostIDs {
            hostsByID.removeValue(forKey: hostID)
        }

        try? persist()
    }
}
