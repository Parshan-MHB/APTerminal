import Foundation
import XCTest
@testable import APTerminalProtocol

final class PasteGuardPolicyTests: XCTestCase {
    func testAllowsShortSingleLinePaste() {
        let policy = PasteGuardPolicy(largePasteByteThreshold: 256, multilineThreshold: 2, warnOnEscapeSequences: true)
        let result = policy.evaluate(Data("ls -la".utf8))

        XCTAssertEqual(result, .allow)
    }

    func testWarnsForMultilinePaste() {
        let policy = PasteGuardPolicy(largePasteByteThreshold: 256, multilineThreshold: 2, warnOnEscapeSequences: true)
        let result = policy.evaluate(Data("echo one\necho two".utf8))

        XCTAssertEqual(result, .confirmLargePaste(lineCount: 2, byteCount: 17))
    }

    func testWarnsForEscapeSequencesWhenEnabled() {
        let policy = PasteGuardPolicy(largePasteByteThreshold: 256, multilineThreshold: 2, warnOnEscapeSequences: true)
        let result = policy.evaluate(Data([0x1B, 0x5B, 0x41]))

        XCTAssertEqual(result, .confirmControlSequence)
    }

    func testAllowsEscapeSequencesWhenWarningDisabled() {
        let policy = PasteGuardPolicy(largePasteByteThreshold: 256, multilineThreshold: 2, warnOnEscapeSequences: false)
        let result = policy.evaluate(Data([0x1B, 0x5B, 0x41]))

        XCTAssertEqual(result, .allow)
    }
}
