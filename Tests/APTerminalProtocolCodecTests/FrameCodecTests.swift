import Foundation
import XCTest
@testable import APTerminalProtocol
@testable import APTerminalProtocolCodec

final class FrameCodecTests: XCTestCase {
    func testFrameHeaderRoundTripPreservesValues() throws {
        let header = FrameHeader(version: .v1, kind: .control, bodyLength: 42)

        let encoded = FrameCodec.encodeHeader(header)
        let decoded = try FrameCodec.decodeHeader(encoded)

        XCTAssertEqual(decoded, header)
    }

    func testFrameRoundTripPreservesPayload() throws {
        let payload = Data("hello".utf8)

        let encoded = FrameCodec.encodeFrame(kind: .terminalOutput, payload: payload)
        let decoded = try FrameCodec.decodeFrame(encoded)

        XCTAssertEqual(decoded.header.kind, .terminalOutput)
        XCTAssertEqual(decoded.header.version, .v1)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testDecodeFrameRejectsTruncatedPayload() throws {
        let payload = Data("hello".utf8)
        let encoded = FrameCodec.encodeFrame(kind: .control, payload: payload)
        let truncated = Data(encoded.dropLast())

        XCTAssertThrowsError(try FrameCodec.decodeFrame(truncated)) { error in
            XCTAssertEqual(
                error as? FrameCodecError,
                .invalidFrameLength(expected: encoded.count, actual: truncated.count)
            )
        }
    }
}
