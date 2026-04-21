import Foundation
import APTerminalProtocol

public struct AuditEventRecord: Codable, Equatable, Sendable {
    public var occurredAt: Date
    public var kind: AuditEventKind
    public var deviceID: DeviceID?
    public var sessionID: SessionID?
    public var note: String?

    public init(
        occurredAt: Date = Date(),
        kind: AuditEventKind,
        deviceID: DeviceID? = nil,
        sessionID: SessionID? = nil,
        note: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.kind = kind
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.note = note
    }
}

public actor AuditLogger {
    private let store: AuditEventStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(store: AuditEventStore) {
        self.store = store
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public init(logURL: URL) {
        self.store = FileAuditEventStore(fileURL: logURL)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultLogURL(appName: String = APTerminalConfiguration.appName) -> URL {
        FileAuditEventStore.defaultFileURL(appName: appName)
    }

    public func log(_ event: AuditEventRecord) throws {
        let payload = try encoder.encode(event)
        let line = payload + Data([0x0A])
        try store.appendLine(line)
    }

    public func trimToLast(_ maxLineCount: Int) throws {
        try store.trimToLast(maxLineCount)
    }

    public func recentEvents(limit: Int) throws -> [AuditEventRecord] {
        let lines = try store.readLines()
        let slice = limit > 0 ? lines.suffix(limit) : ArraySlice(lines)
        return try slice.map { line in
            try decoder.decode(AuditEventRecord.self, from: line)
        }
    }
}
