import Foundation

public enum FrameKind: UInt8, Codable, Sendable {
    case control = 1
    case terminalInput = 2
    case terminalOutput = 3
    case heartbeat = 4
    case secureTransport = 5
}

public struct FrameHeader: Equatable, Sendable {
    public static let encodedSize = 7

    public var version: ProtocolVersion
    public var kind: FrameKind
    public var bodyLength: UInt32

    public init(version: ProtocolVersion, kind: FrameKind, bodyLength: UInt32) {
        self.version = version
        self.kind = kind
        self.bodyLength = bodyLength
    }
}

public enum TerminalStreamDirection: String, Codable, Sendable {
    case input
    case output
}

public struct TerminalStreamChunk: Codable, Equatable, Sendable {
    public var sessionID: SessionID
    public var direction: TerminalStreamDirection
    public var sequenceNumber: UInt64
    public var data: Data

    public init(
        sessionID: SessionID,
        direction: TerminalStreamDirection,
        sequenceNumber: UInt64,
        data: Data
    ) {
        self.sessionID = sessionID
        self.direction = direction
        self.sequenceNumber = sequenceNumber
        self.data = data
    }
}
