public enum ProtocolVersion: UInt16, CaseIterable, Codable, Sendable {
    case v1 = 1

    public static let current: ProtocolVersion = .v1
}
