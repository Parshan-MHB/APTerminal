import Foundation
import XCTest
@testable import APTerminalProtocol
@testable import APTerminalProtocolCodec
@testable import APTerminalTransport

final class FrameStreamAccumulatorTests: XCTestCase {
    func testAppendRejectsOversizedFrameBody() throws {
        var accumulator = FrameStreamAccumulator(maximumFrameBodyBytes: 16, maximumBufferedBytes: 32)
        let frame = FrameCodec.encodeFrame(kind: .control, payload: Data(repeating: 0x61, count: 20))

        XCTAssertThrowsError(try accumulator.append(frame)) { error in
            XCTAssertEqual(
                error as? FrameStreamAccumulatorError,
                .inboundFrameBodyLimitExceeded(actual: 20, limit: 16)
            )
        }
    }

    func testAppendRejectsInboundBufferOverflow() throws {
        var accumulator = FrameStreamAccumulator(maximumFrameBodyBytes: 128, maximumBufferedBytes: 12)
        let partialFrame = Data(repeating: 0x00, count: 13)

        XCTAssertThrowsError(try accumulator.append(partialFrame)) { error in
            XCTAssertEqual(
                error as? FrameStreamAccumulatorError,
                .inboundBufferLimitExceeded(limit: 12)
            )
        }
    }
}
