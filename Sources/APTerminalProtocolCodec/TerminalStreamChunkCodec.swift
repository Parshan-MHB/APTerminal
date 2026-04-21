import Foundation
import APTerminalProtocol

public enum TerminalStreamChunkCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ chunk: TerminalStreamChunk) throws -> Data {
        try makeEncoder().encode(chunk)
    }

    public static func decode(_ data: Data) throws -> TerminalStreamChunk {
        try makeDecoder().decode(TerminalStreamChunk.self, from: data)
    }
}
