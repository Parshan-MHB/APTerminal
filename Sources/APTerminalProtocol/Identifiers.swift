import Foundation

public struct DeviceID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func random() -> DeviceID {
        DeviceID(rawValue: UUID().uuidString.lowercased())
    }
}

public struct MessageID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func random() -> MessageID {
        MessageID(rawValue: UUID().uuidString.lowercased())
    }
}

public struct SessionID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func random() -> SessionID {
        SessionID(rawValue: UUID().uuidString.lowercased())
    }
}
