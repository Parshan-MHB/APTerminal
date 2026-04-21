import Foundation
import APTerminalProtocol

public struct TerminalBufferSnapshot: Equatable, Sendable {
    public var lines: [String]
    public var cursorRow: Int
    public var cursorColumn: Int

    public init(lines: [String], cursorRow: Int, cursorColumn: Int) {
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
    }

    public var joinedText: String {
        lines.joined(separator: "\n")
    }

    public func renderedText(showCursor: Bool) -> String {
        guard showCursor else {
            return joinedText
        }

        var renderedLines = lines.map { Array($0) }

        if renderedLines.isEmpty {
            renderedLines = [[]]
        }

        let safeRow = max(0, cursorRow)

        while renderedLines.count <= safeRow {
            renderedLines.append([])
        }

        if renderedLines[safeRow].count < cursorColumn {
            renderedLines[safeRow].append(
                contentsOf: repeatElement(Character(" "), count: cursorColumn - renderedLines[safeRow].count)
            )
        }

        let cursorCharacter = Character("█")

        if renderedLines[safeRow].count == cursorColumn {
            renderedLines[safeRow].append(cursorCharacter)
        } else {
            renderedLines[safeRow].insert(cursorCharacter, at: cursorColumn)
        }

        return renderedLines.map { String($0) }.joined(separator: "\n")
    }
}

public actor TerminalBufferStore {
    private enum ParserState {
        case normal
        case escape
        case controlSequenceIntroducer(String)
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private let maxLines: Int
    private var lines: [[Character]]
    private var cursorRow: Int
    private var cursorColumn: Int
    private var savedCursor: (row: Int, column: Int)?
    private var parserState: ParserState
    private var transcriptLines: [[Character]]
    private var transcriptCursorColumn: Int
    private var transcriptParserState: ParserState

    public init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
        self.lines = [[]]
        self.cursorRow = 0
        self.cursorColumn = 0
        self.savedCursor = nil
        self.parserState = .normal
        self.transcriptLines = [[]]
        self.transcriptCursorColumn = 0
        self.transcriptParserState = .normal
    }

    public func clear() {
        reset()
        parserState = .normal
        resetTranscript()
        transcriptParserState = .normal
    }

    public func consume(_ chunk: TerminalStreamChunk) {
        let decoded = String(decoding: chunk.data, as: UTF8.self)

        for scalar in decoded.unicodeScalars {
            process(scalar)
            processTranscript(scalar)
        }

        trimScrollbackIfNeeded()
        trimTranscriptIfNeeded()
    }

    public func snapshot() -> TerminalBufferSnapshot {
        TerminalBufferSnapshot(
            lines: normalizedSnapshotLines(),
            cursorRow: cursorRow,
            cursorColumn: cursorColumn
        )
    }

    public func transcriptText() -> String {
        normalizedTranscriptLines().joined(separator: "\n")
    }

    private func process(_ scalar: UnicodeScalar) {
        switch parserState {
        case .normal:
            processNormal(scalar)
        case .escape:
            processEscape(scalar)
        case let .controlSequenceIntroducer(buffer):
            processControlSequenceIntroducer(scalar, buffer: buffer)
        case .operatingSystemCommand:
            processOperatingSystemCommand(scalar)
        case .operatingSystemCommandEscape:
            processOperatingSystemCommandEscape(scalar)
        }
    }

    private func processNormal(_ scalar: UnicodeScalar) {
        switch scalar {
        case "\u{1B}":
            parserState = .escape
        case "\n":
            lineFeed()
        case "\r":
            cursorColumn = 0
        case "\t":
            let nextStop = ((cursorColumn / 4) + 1) * 4
            while cursorColumn < nextStop {
                write(" ")
            }
        case "\u{8}", "\u{7F}":
            if cursorColumn > 0 {
                cursorColumn -= 1
            }
        default:
            guard scalar.value >= 0x20 else {
                return
            }

            write(Character(scalar))
        }
    }

    private func processEscape(_ scalar: UnicodeScalar) {
        switch scalar {
        case "[":
            parserState = .controlSequenceIntroducer("")
        case "]":
            parserState = .operatingSystemCommand
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            parserState = .normal
        case "8":
            restoreCursor()
            parserState = .normal
        case "c":
            reset()
            parserState = .normal
        default:
            parserState = .normal
        }
    }

    private func processControlSequenceIntroducer(_ scalar: UnicodeScalar, buffer: String) {
        if scalar.value >= 0x30, scalar.value <= 0x3F {
            parserState = .controlSequenceIntroducer(buffer + String(scalar))
            return
        }

        if scalar.value >= 0x20, scalar.value <= 0x2F {
            parserState = .controlSequenceIntroducer(buffer)
            return
        }

        applyControlSequence(final: scalar, parameters: buffer)
        parserState = .normal
    }

    private func processOperatingSystemCommand(_ scalar: UnicodeScalar) {
        switch scalar {
        case "\u{7}":
            parserState = .normal
        case "\u{1B}":
            parserState = .operatingSystemCommandEscape
        default:
            break
        }
    }

    private func processOperatingSystemCommandEscape(_ scalar: UnicodeScalar) {
        if scalar == "\\" {
            parserState = .normal
        } else {
            parserState = .operatingSystemCommand
        }
    }

    private func processTranscript(_ scalar: UnicodeScalar) {
        switch transcriptParserState {
        case .normal:
            processTranscriptNormal(scalar)
        case .escape:
            processTranscriptEscape(scalar)
        case let .controlSequenceIntroducer(buffer):
            processTranscriptControlSequenceIntroducer(scalar, buffer: buffer)
        case .operatingSystemCommand:
            processTranscriptOperatingSystemCommand(scalar)
        case .operatingSystemCommandEscape:
            processTranscriptOperatingSystemCommandEscape(scalar)
        }
    }

    private func processTranscriptNormal(_ scalar: UnicodeScalar) {
        switch scalar {
        case "\u{1B}":
            transcriptParserState = .escape
        case "\n":
            transcriptLineFeed()
        case "\r":
            transcriptCursorColumn = 0
        case "\t":
            let nextStop = ((transcriptCursorColumn / 4) + 1) * 4
            while transcriptCursorColumn < nextStop {
                transcriptWrite(" ")
            }
        case "\u{8}", "\u{7F}":
            if transcriptCursorColumn > 0 {
                transcriptCursorColumn -= 1
            }
        default:
            guard scalar.value >= 0x20 else {
                return
            }

            transcriptWrite(Character(scalar))
        }
    }

    private func processTranscriptEscape(_ scalar: UnicodeScalar) {
        switch scalar {
        case "[":
            transcriptParserState = .controlSequenceIntroducer("")
        case "]":
            transcriptParserState = .operatingSystemCommand
        case "c":
            resetTranscript()
            transcriptParserState = .normal
        default:
            transcriptParserState = .normal
        }
    }

    private func processTranscriptControlSequenceIntroducer(_ scalar: UnicodeScalar, buffer: String) {
        if scalar.value >= 0x30, scalar.value <= 0x3F {
            transcriptParserState = .controlSequenceIntroducer(buffer + String(scalar))
            return
        }

        if scalar.value >= 0x20, scalar.value <= 0x2F {
            transcriptParserState = .controlSequenceIntroducer(buffer)
            return
        }

        transcriptParserState = .normal
    }

    private func processTranscriptOperatingSystemCommand(_ scalar: UnicodeScalar) {
        switch scalar {
        case "\u{7}":
            transcriptParserState = .normal
        case "\u{1B}":
            transcriptParserState = .operatingSystemCommandEscape
        default:
            break
        }
    }

    private func processTranscriptOperatingSystemCommandEscape(_ scalar: UnicodeScalar) {
        if scalar == "\\" {
            transcriptParserState = .normal
        } else {
            transcriptParserState = .operatingSystemCommand
        }
    }

    private func applyControlSequence(final: UnicodeScalar, parameters: String) {
        let values = parseCSIParameters(parameters)

        switch final {
        case "A":
            cursorRow = max(0, cursorRow - firstParameter(values, default: 1))
        case "B":
            cursorRow += firstParameter(values, default: 1)
            ensureLineExists(at: cursorRow)
        case "C":
            cursorColumn += firstParameter(values, default: 1)
        case "D":
            cursorColumn = max(0, cursorColumn - firstParameter(values, default: 1))
        case "E":
            cursorRow += firstParameter(values, default: 1)
            ensureLineExists(at: cursorRow)
            cursorColumn = 0
        case "F":
            cursorRow = max(0, cursorRow - firstParameter(values, default: 1))
            cursorColumn = 0
        case "G":
            cursorColumn = max(0, firstParameter(values, default: 1) - 1)
        case "H", "f":
            let row = max(1, values[safe: 0] ?? 1) - 1
            let column = max(1, values[safe: 1] ?? 1) - 1
            cursorRow = row
            cursorColumn = column
            ensureLineExists(at: cursorRow)
        case "J":
            applyEraseInDisplay(mode: values[safe: 0] ?? 0)
        case "K":
            applyEraseInLine(mode: values[safe: 0] ?? 0)
        case "P":
            applyDeleteCharacters(count: firstParameter(values, default: 1))
        case "X":
            applyEraseCharacters(count: firstParameter(values, default: 1))
        case "m":
            break
        case "s":
            savedCursor = (cursorRow, cursorColumn)
        case "u":
            restoreCursor()
        default:
            break
        }
    }

    private func applyEraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            ensureLineExists(at: cursorRow)
            if cursorColumn < lines[cursorRow].count {
                lines[cursorRow].removeSubrange(cursorColumn...)
            }
            if cursorRow + 1 < lines.count {
                for row in (cursorRow + 1)..<lines.count {
                    lines[row].removeAll(keepingCapacity: false)
                }
            }
        case 1:
            ensureLineExists(at: cursorRow)
            if cursorColumn >= 0, lines[cursorRow].isEmpty == false {
                let upperBound = min(cursorColumn, lines[cursorRow].count - 1)
                if upperBound >= 0 {
                    for index in 0...upperBound {
                        lines[cursorRow][index] = " "
                    }
                }
            }
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    lines[row].removeAll(keepingCapacity: false)
                }
            }
        case 2:
            reset()
        default:
            break
        }
    }

    private func applyEraseInLine(mode: Int) {
        ensureLineExists(at: cursorRow)

        switch mode {
        case 0:
            if cursorColumn < lines[cursorRow].count {
                lines[cursorRow].removeSubrange(cursorColumn...)
            }
        case 1:
            guard lines[cursorRow].isEmpty == false else { return }
            let upperBound = min(cursorColumn, lines[cursorRow].count - 1)
            if upperBound >= 0 {
                for index in 0...upperBound {
                    lines[cursorRow][index] = " "
                }
            }
        case 2:
            lines[cursorRow].removeAll(keepingCapacity: false)
            cursorColumn = 0
        default:
            break
        }
    }

    private func applyDeleteCharacters(count: Int) {
        ensureLineExists(at: cursorRow)
        guard count > 0, cursorColumn < lines[cursorRow].count else {
            return
        }

        let endIndex = min(cursorColumn + count, lines[cursorRow].count)
        lines[cursorRow].removeSubrange(cursorColumn..<endIndex)
    }

    private func applyEraseCharacters(count: Int) {
        ensureLineExists(at: cursorRow)
        guard count > 0 else {
            return
        }

        let lastIndex = max(cursorColumn, min(cursorColumn + count - 1, max(0, lines[cursorRow].count - 1)))
        guard lines[cursorRow].isEmpty == false, lastIndex >= cursorColumn else {
            return
        }

        for index in cursorColumn...lastIndex {
            lines[cursorRow][index] = " "
        }
    }

    private func write(_ character: Character) {
        ensureLineExists(at: cursorRow)

        if lines[cursorRow].count < cursorColumn {
            lines[cursorRow].append(
                contentsOf: repeatElement(Character(" "), count: cursorColumn - lines[cursorRow].count)
            )
        }

        if cursorColumn == lines[cursorRow].count {
            lines[cursorRow].append(character)
        } else {
            lines[cursorRow][cursorColumn] = character
        }

        cursorColumn += 1
    }

    private func lineFeed() {
        cursorRow += 1
        cursorColumn = 0
        ensureLineExists(at: cursorRow)
    }

    private func ensureLineExists(at row: Int) {
        while lines.count <= row {
            lines.append([])
        }
    }

    private func restoreCursor() {
        guard let savedCursor else { return }
        cursorRow = savedCursor.row
        cursorColumn = savedCursor.column
        ensureLineExists(at: cursorRow)
    }

    private func reset() {
        lines = [[]]
        cursorRow = 0
        cursorColumn = 0
        savedCursor = nil
    }

    private func resetTranscript() {
        transcriptLines = [[]]
        transcriptCursorColumn = 0
    }

    private func trimScrollbackIfNeeded() {
        guard lines.count > maxLines else { return }

        let overflow = lines.count - maxLines
        lines.removeFirst(overflow)
        cursorRow = max(0, cursorRow - overflow)

        if let savedCursor {
            self.savedCursor = (
                row: max(0, savedCursor.row - overflow),
                column: savedCursor.column
            )
        }
    }

    private func trimTranscriptIfNeeded() {
        guard transcriptLines.count > maxLines else { return }

        let overflow = transcriptLines.count - maxLines
        transcriptLines.removeFirst(overflow)
    }

    private func parseCSIParameters(_ raw: String) -> [Int] {
        let normalized = raw.replacingOccurrences(of: "?", with: "")
        guard normalized.isEmpty == false else {
            return []
        }

        return normalized
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private func firstParameter(_ values: [Int], default defaultValue: Int) -> Int {
        max(defaultValue, values.first ?? defaultValue)
    }

    private func normalizedSnapshotLines() -> [String] {
        var normalized = lines.map { String($0) }

        while normalized.count > 1, normalized.last?.isEmpty == true, cursorRow < normalized.count - 1 {
            normalized.removeLast()
        }

        return normalized
    }

    private func normalizedTranscriptLines() -> [String] {
        var normalized = transcriptLines.map { String($0) }

        while normalized.count > 1, normalized.last?.isEmpty == true {
            normalized.removeLast()
        }

        return normalized
    }

    private func transcriptWrite(_ character: Character) {
        ensureTranscriptLineExists()

        if transcriptLines[transcriptLines.count - 1].count < transcriptCursorColumn {
            transcriptLines[transcriptLines.count - 1].append(
                contentsOf: repeatElement(Character(" "), count: transcriptCursorColumn - transcriptLines[transcriptLines.count - 1].count)
            )
        }

        if transcriptCursorColumn == transcriptLines[transcriptLines.count - 1].count {
            transcriptLines[transcriptLines.count - 1].append(character)
        } else {
            transcriptLines[transcriptLines.count - 1][transcriptCursorColumn] = character
        }

        transcriptCursorColumn += 1
    }

    private func transcriptLineFeed() {
        transcriptLines.append([])
        transcriptCursorColumn = 0
    }

    private func ensureTranscriptLineExists() {
        if transcriptLines.isEmpty {
            transcriptLines = [[]]
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }

        return self[index]
    }
}
