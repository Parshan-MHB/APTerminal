import Foundation

public struct PairingBootstrapPayload: Codable, Equatable, Sendable {
    public var hostIdentity: DeviceIdentity
    public var host: String
    public var port: UInt16
    public var connectionMode: HostConnectionMode
    public var endpointKind: HostEndpointKind
    public var token: PairingToken
    public var hostPublicKey: Data

    public init(
        hostIdentity: DeviceIdentity,
        host: String,
        port: UInt16,
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind,
        token: PairingToken,
        hostPublicKey: Data
    ) {
        self.hostIdentity = hostIdentity
        self.host = host
        self.port = port
        self.connectionMode = connectionMode
        self.endpointKind = endpointKind
        self.token = token
        self.hostPublicKey = hostPublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case hostIdentity
        case host
        case port
        case connectionMode
        case endpointKind
        case token
        case hostPublicKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostIdentity = try container.decode(DeviceIdentity.self, forKey: .hostIdentity)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        connectionMode = try container.decodeIfPresent(HostConnectionMode.self, forKey: .connectionMode) ?? .lan
        endpointKind = try container.decodeIfPresent(HostEndpointKind.self, forKey: .endpointKind) ?? .localNetwork
        token = try container.decode(PairingToken.self, forKey: .token)
        hostPublicKey = try container.decode(Data.self, forKey: .hostPublicKey)
    }

    public func encodedJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
