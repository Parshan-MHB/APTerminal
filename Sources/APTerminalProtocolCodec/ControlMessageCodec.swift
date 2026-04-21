import Foundation
import APTerminalProtocol

public enum ControlMessageCodec {
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

    public static func encode(_ message: ControlMessage) throws -> Data {
        try makeEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try makeDecoder().decode(ControlMessage.self, from: data)
    }

    public static func encodeEnvelope(_ envelope: ControlEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    public static func decodeEnvelope(_ data: Data) throws -> ControlEnvelope {
        try makeDecoder().decode(ControlEnvelope.self, from: data)
    }
}
