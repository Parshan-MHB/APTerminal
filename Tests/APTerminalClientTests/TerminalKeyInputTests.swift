import Foundation
import XCTest
@testable import APTerminalClient

final class TerminalKeyInputTests: XCTestCase {
    func testAltCharacterEncodesAsEscapePrefix() {
        XCTAssertEqual(TerminalKeyInputEncoder.encode(.alt("b")), Data([0x1B, 0x62]))
    }

    func testFunctionKeyOneUsesSS3Sequence() {
        XCTAssertEqual(TerminalKeyInputEncoder.encode(.function(1)), Data([0x1B, 0x4F, 0x50]))
    }

    func testFunctionKeyTwelveUsesCSISequence() {
        XCTAssertEqual(
            TerminalKeyInputEncoder.encode(.function(12)),
            Data([0x1B, 0x5B, 0x32, 0x34, 0x7E])
        )
    }

    func testUnsupportedFunctionKeyProducesEmptyData() {
        XCTAssertEqual(TerminalKeyInputEncoder.encode(.function(13)), Data())
    }
}
