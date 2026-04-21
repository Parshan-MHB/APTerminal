import Foundation
import APTerminalProtocol
import APTerminalProtocolCodec

public enum FrameStreamAccumulatorError: Error, Equatable {
    case inboundBufferLimitExceeded(limit: Int)
    case inboundFrameBodyLimitExceeded(actual: Int, limit: Int)
}

public struct FrameStreamAccumulator: Sendable {
    private var buffer = Data()
    private let maximumFrameBodyBytes: Int
    private let maximumBufferedBytes: Int

    public init(
        maximumFrameBodyBytes: Int = APTerminalConfiguration.defaultTransportMaximumInboundFrameBytes,
        maximumBufferedBytes: Int = APTerminalConfiguration.defaultTransportMaximumBufferedInboundBytes
    ) {
        self.maximumFrameBodyBytes = maximumFrameBodyBytes
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    public mutating func append(_ data: Data) throws -> [DecodedFrame] {
        buffer.append(data)
        guard buffer.count <= maximumBufferedBytes else {
            throw FrameStreamAccumulatorError.inboundBufferLimitExceeded(limit: maximumBufferedBytes)
        }
        var decodedFrames: [DecodedFrame] = []

        while buffer.count >= FrameHeader.encodedSize {
            let headerData = Data(buffer.prefix(FrameHeader.encodedSize))
            let header = try FrameCodec.decodeHeader(headerData)
            let bodyLength = Int(header.bodyLength)
            guard bodyLength <= maximumFrameBodyBytes else {
                throw FrameStreamAccumulatorError.inboundFrameBodyLimitExceeded(
                    actual: bodyLength,
                    limit: maximumFrameBodyBytes
                )
            }
            let fullFrameLength = FrameHeader.encodedSize + Int(header.bodyLength)

            guard buffer.count >= fullFrameLength else {
                break
            }

            let frameData = Data(buffer.prefix(fullFrameLength))
            let frame = try FrameCodec.decodeFrame(frameData)
            decodedFrames.append(frame)
            buffer.removeFirst(fullFrameLength)
        }

        return decodedFrames
    }
}
