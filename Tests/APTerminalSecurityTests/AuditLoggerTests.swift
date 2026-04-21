import XCTest
@testable import APTerminalProtocol
@testable import APTerminalSecurity

final class AuditLoggerTests: XCTestCase {
    func testAuditLoggerUsesStoreBoundaryAndTrimsPersistedEvents() async throws {
        let store = InMemoryAuditEventStore()
        let logger = AuditLogger(store: store)

        try await logger.log(.init(kind: .devicePaired, note: "paired"))
        try await logger.log(.init(kind: .connectionAccepted, note: "accepted"))
        try await logger.trimToLast(1)

        let lines = store.storedLines()
        XCTAssertEqual(lines.count, 1)

        let payload = try XCTUnwrap(lines.first)
        let decoded = try JSONDecoder.iso8601.decode(AuditEventRecord.self, from: payload)
        XCTAssertEqual(decoded.kind, .connectionAccepted)
        XCTAssertEqual(decoded.note, "accepted")
    }

    func testRecentEventsReturnsNewestRetainedRecords() async throws {
        let store = InMemoryAuditEventStore()
        let logger = AuditLogger(store: store)

        try await logger.log(.init(kind: .devicePaired, note: "first"))
        try await logger.log(.init(kind: .connectionAccepted, note: "second"))
        try await logger.log(.init(kind: .sessionAttached, note: "third"))

        let events = try await logger.recentEvents(limit: 2)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].note, "second")
        XCTAssertEqual(events[1].note, "third")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
