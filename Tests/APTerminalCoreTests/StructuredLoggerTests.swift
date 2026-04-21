import XCTest
@testable import APTerminalCore

final class StructuredLoggerTests: XCTestCase {
    func testLoggerFormatsSeverityCategoryAndMetadata() {
        let sink = InMemoryLogSink()
        let logger = StructuredLogger(
            subsystem: "com.apterminal",
            category: "HostServer",
            sink: sink
        )

        logger.notice("Listener ready", metadata: ["port": "8443", "transport": "tcp"])

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertTrue(sink.records[0].contains("[notice]"))
        XCTAssertTrue(sink.records[0].contains("com.apterminal.HostServer"))
        XCTAssertTrue(sink.records[0].contains("Listener ready"))
        XCTAssertTrue(sink.records[0].contains("port=8443"))
        XCTAssertTrue(sink.records[0].contains("transport=tcp"))
    }
}
