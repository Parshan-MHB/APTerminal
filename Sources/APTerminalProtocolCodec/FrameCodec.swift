import Foundation
import APTerminalProtocol

public enum FrameCodecError: Error, Equatable {
    case invalidHeaderLength(Int)
    case invalidFrameLength(expected: Int, actual: Int)
    case unsupportedVersion(UInt16)
    case unknownFrameKind(UInt8)
}

public struct DecodedFrame: Equatable, Sendable {
    public var header: FrameHeader
    public var payload: Data

    public init(header: FrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public enum FrameCodec {
    public static func encodeHeader(_ header: FrameHeader) -> Data {
        var data = Data()

        let version = header.version.rawValue.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: version, Array.init))
        data.append(header.kind.rawValue)

        let bodyLength = header.bodyLength.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: bodyLength, Array.init))

        return data
    }

    public static func decodeHeader(_ data: Data) throws -> FrameHeader {
        guard data.count == FrameHeader.encodedSize else {
            throw FrameCodecError.invalidHeaderLength(data.count)
        }

        let versionRaw = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: 0, as: UInt16.self).bigEndian
        }

        guard let version = ProtocolVersion(rawValue: versionRaw) else {
            throw FrameCodecError.unsupportedVersion(versionRaw)
        }

        let kindRaw = data[2]

        guard let kind = FrameKind(rawValue: kindRaw) else {
            throw FrameCodecError.unknownFrameKind(kindRaw)
        }

        let bodyLength = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: 3, as: UInt32.self).bigEndian
        }

        return FrameHeader(version: version, kind: kind, bodyLength: bodyLength)
    }

    public static func encodeFrame(kind: FrameKind, payload: Data, version: ProtocolVersion = .current) -> Data {
        let header = FrameHeader(version: version, kind: kind, bodyLength: UInt32(payload.count))
        return encodeHeader(header) + payload
    }

    public static func decodeFrame(_ data: Data) throws -> DecodedFrame {
        guard data.count >= FrameHeader.encodedSize else {
            throw FrameCodecError.invalidHeaderLength(data.count)
        }

        let headerData = data.prefix(FrameHeader.encodedSize)
        let header = try decodeHeader(Data(headerData))
        let expectedFrameLength = FrameHeader.encodedSize + Int(header.bodyLength)

        guard data.count == expectedFrameLength else {
            throw FrameCodecError.invalidFrameLength(expected: expectedFrameLength, actual: data.count)
        }

        let payload = Data(data.dropFirst(FrameHeader.encodedSize))
        return DecodedFrame(header: header, payload: payload)
    }
}
