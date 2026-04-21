import Foundation

public enum PasteGuardDecision: Equatable, Sendable {
    case allow
    case confirmLargePaste(lineCount: Int, byteCount: Int)
    case confirmControlSequence
}

public struct PasteGuardPolicy: Codable, Equatable, Sendable {
    public var largePasteByteThreshold: Int
    public var multilineThreshold: Int
    public var warnOnEscapeSequences: Bool

    public init(
        largePasteByteThreshold: Int = 256,
        multilineThreshold: Int = 2,
        warnOnEscapeSequences: Bool = true
    ) {
        self.largePasteByteThreshold = largePasteByteThreshold
        self.multilineThreshold = multilineThreshold
        self.warnOnEscapeSequences = warnOnEscapeSequences
    }

    public func evaluate(_ data: Data) -> PasteGuardDecision {
        if warnOnEscapeSequences, data.contains(0x1B) {
            return .confirmControlSequence
        }

        let lineCount = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count

        if data.count >= largePasteByteThreshold || lineCount >= multilineThreshold {
            return .confirmLargePaste(lineCount: lineCount, byteCount: data.count)
        }

        return .allow
    }
}
