import CryptoKit
import Foundation
import APTerminalProtocol

public enum SecurePayloadKind: UInt8, Sendable {
    case control = 1
    case terminalInput = 2
    case terminalOutput = 3
    case heartbeat = 4

    init(frameKind: FrameKind) throws {
        switch frameKind {
        case .control:
            self = .control
        case .terminalInput:
            self = .terminalInput
        case .terminalOutput:
            self = .terminalOutput
        case .heartbeat:
            self = .heartbeat
        case .secureTransport:
            throw SecureTransportError.unsupportedFrameKind(.secureTransport)
        }
    }

    var frameKind: FrameKind {
        switch self {
        case .control:
            return .control
        case .terminalInput:
            return .terminalInput
        case .terminalOutput:
            return .terminalOutput
        case .heartbeat:
            return .heartbeat
        }
    }
}

public enum SecureSessionRole: Sendable {
    case client
    case server
}

public struct SecureSessionKeys: Sendable {
    public var outboundKey: SymmetricKey
    public var inboundKey: SymmetricKey

    public init(outboundKey: SymmetricKey, inboundKey: SymmetricKey) {
        self.outboundKey = outboundKey
        self.inboundKey = inboundKey
    }
}

public enum SecureTransportError: Error, Equatable {
    case secureSessionNotEstablished
    case unsupportedFrameKind(FrameKind)
    case malformedSecureFrame
    case unknownPayloadKind(UInt8)
    case decryptFailed
    case inboundSequenceMismatch(expected: UInt64, actual: UInt64)
    case plaintextFrameRejected(FrameKind)
}

struct SecureDecodedPayload: Sendable {
    public var kind: SecurePayloadKind
    public var sequenceNumber: UInt64
    public var payload: Data

    init(kind: SecurePayloadKind, sequenceNumber: UInt64, payload: Data) {
        self.kind = kind
        self.sequenceNumber = sequenceNumber
        self.payload = payload
    }
}

public enum SecureSessionKeyDerivation {
    public static func deriveKeys(
        sharedSecret: SharedSecret,
        transcript: Data,
        role: SecureSessionRole
    ) -> SecureSessionKeys {
        let salt = Data(SHA256.hash(data: transcript))
        let clientToHost = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("APTerminal Secure Transport client->host".utf8),
            outputByteCount: 32
        )
        let hostToClient = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("APTerminal Secure Transport host->client".utf8),
            outputByteCount: 32
        )

        switch role {
        case .client:
            return SecureSessionKeys(outboundKey: clientToHost, inboundKey: hostToClient)
        case .server:
            return SecureSessionKeys(outboundKey: hostToClient, inboundKey: clientToHost)
        }
    }
}

enum SecureTransportCodec {
    private static let tagLength = 16

    static func encodeFrame(
        kind: FrameKind,
        payload: Data,
        sequenceNumber: UInt64,
        key: SymmetricKey
    ) throws -> Data {
        let payloadKind = try SecurePayloadKind(frameKind: kind)
        let nonce = try nonce(for: sequenceNumber)
        let aad = additionalAuthenticatedData(sequenceNumber: sequenceNumber, payloadKind: payloadKind)
        let sealedBox = try ChaChaPoly.seal(payload, using: key, nonce: nonce, authenticating: aad)

        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: sequenceNumber.bigEndian, Array.init))
        data.append(payloadKind.rawValue)
        data.append(sealedBox.ciphertext)
        data.append(sealedBox.tag)
        return data
    }

    static func decodeFrame(
        _ data: Data,
        expectedSequenceNumber: UInt64,
        key: SymmetricKey
    ) throws -> SecureDecodedPayload {
        guard data.count >= 9 + tagLength else {
            throw SecureTransportError.malformedSecureFrame
        }

        let sequenceNumber = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
        }

        guard sequenceNumber == expectedSequenceNumber else {
            throw SecureTransportError.inboundSequenceMismatch(expected: expectedSequenceNumber, actual: sequenceNumber)
        }

        let payloadKindRaw = data[8]
        guard let payloadKind = SecurePayloadKind(rawValue: payloadKindRaw) else {
            throw SecureTransportError.unknownPayloadKind(payloadKindRaw)
        }

        let encryptedBytes = Data(data.dropFirst(9))
        guard encryptedBytes.count >= tagLength else {
            throw SecureTransportError.malformedSecureFrame
        }

        let ciphertext = encryptedBytes.dropLast(tagLength)
        let tag = encryptedBytes.suffix(tagLength)
        let nonce = try nonce(for: sequenceNumber)
        let aad = additionalAuthenticatedData(sequenceNumber: sequenceNumber, payloadKind: payloadKind)

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            let payload = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
            return SecureDecodedPayload(kind: payloadKind, sequenceNumber: sequenceNumber, payload: payload)
        } catch {
            throw SecureTransportError.decryptFailed
        }
    }

    private static func nonce(for sequenceNumber: UInt64) throws -> ChaChaPoly.Nonce {
        var nonceData = Data(repeating: 0, count: 12)
        nonceData.replaceSubrange(4..<12, with: withUnsafeBytes(of: sequenceNumber.bigEndian, Array.init))
        return try ChaChaPoly.Nonce(data: nonceData)
    }

    private static func additionalAuthenticatedData(
        sequenceNumber: UInt64,
        payloadKind: SecurePayloadKind
    ) -> Data {
        var data = Data("APTerminalSecureTransport/v1".utf8)
        data.append(payloadKind.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: sequenceNumber.bigEndian, Array.init))
        return data
    }
}
