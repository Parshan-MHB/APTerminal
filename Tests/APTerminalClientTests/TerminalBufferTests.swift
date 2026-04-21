import Foundation
import XCTest
@testable import APTerminalClient
@testable import APTerminalProtocol

final class TerminalBufferTests: XCTestCase {
    func testCarriageReturnOverwritesExistingCharacters() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("hello\rY"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["Yello"])
        XCTAssertEqual(snapshot.cursorRow, 0)
        XCTAssertEqual(snapshot.cursorColumn, 1)
    }

    func testBackspaceMovesCursorLeftForOverwrite() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("ab\u{8}Z"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["aZ"])
        XCTAssertEqual(snapshot.cursorColumn, 2)
    }

    func testControlSequenceMovesCursorLeft() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("hello\u{1B}[2Dyy"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["helyy"])
    }

    func testOperatingSystemCommandSequenceIsIgnored() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("abc\u{1B}]0;title\u{7}def"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["abcdef"])
    }

    func testRenderedTextCanShowCursor() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("abc"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.renderedText(showCursor: true), "abc█")
    }

    func testEraseLineClearsBeforeWritingNewContent() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("hello\r\u{1B}[2Kabc"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["abc"])
    }

    func testDeleteCharactersRemovesTrailingCharactersFromCursor() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("abcdef\u{1B}[3D\u{1B}[2P"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["abcf"])
    }

    func testEraseCharactersReplacesCharactersWithSpaces() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("abcdef\u{1B}[4D\u{1B}[2X"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["ab  ef"])
    }

    func testColorSequencesDoNotPolluteRenderedText() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("\u{1B}[31merror\u{1B}[0m"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["error"])
    }

    func testClearScreenAndHomeBehaveLikeCommonFullScreenRedraw() async {
        let buffer = TerminalBufferStore()
        await buffer.consume(chunk("hello\nworld\u{1B}[H\u{1B}[Jdone"))
        let snapshot = await buffer.snapshot()

        XCTAssertEqual(snapshot.lines, ["done"])
    }

    private func chunk(_ text: String) -> TerminalStreamChunk {
        TerminalStreamChunk(
            sessionID: .random(),
            direction: .output,
            sequenceNumber: 1,
            data: Data(text.utf8)
        )
    }
}
