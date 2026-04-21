import Foundation

public struct HelloMessage: Codable, Equatable, Sendable {
    public var role: PeerRole
    public var device: DeviceIdentity
    public var supportedVersions: [ProtocolVersion]
    public var signingPublicKey: Data?
    public var authChallenge: AuthChallengeMessage?
    public var secureSessionOffer: SecureSessionOfferMessage?
    public var connectionMode: HostConnectionMode?
    public var endpointKind: HostEndpointKind?
    public var previewAccessModes: [HostConnectionMode]?

    public init(
        role: PeerRole,
        device: DeviceIdentity,
        supportedVersions: [ProtocolVersion],
        signingPublicKey: Data? = nil,
        authChallenge: AuthChallengeMessage? = nil,
        secureSessionOffer: SecureSessionOfferMessage? = nil,
        connectionMode: HostConnectionMode? = nil,
        endpointKind: HostEndpointKind? = nil,
        previewAccessModes: [HostConnectionMode]? = nil
    ) {
        self.role = role
        self.device = device
        self.supportedVersions = supportedVersions
        self.signingPublicKey = signingPublicKey
        self.authChallenge = authChallenge
        self.secureSessionOffer = secureSessionOffer
        self.connectionMode = connectionMode
        self.endpointKind = endpointKind
        self.previewAccessModes = previewAccessModes
    }
}

public struct SecureSessionOfferMessage: Codable, Equatable, Sendable {
    public var ephemeralPublicKey: Data
    public var issuedAt: Date
    public var expiresAt: Date
    public var signature: Data

    public init(
        ephemeralPublicKey: Data,
        issuedAt: Date,
        expiresAt: Date,
        signature: Data
    ) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    public static func signingPayload(
        clientDeviceID: DeviceID,
        clientSigningPublicKey: Data,
        hostDeviceID: DeviceID,
        hostEphemeralPublicKey: Data,
        issuedAt: Date,
        expiresAt: Date,
        protocolVersion: ProtocolVersion
    ) -> Data {
        let issuedAtSeconds = Int64(issuedAt.timeIntervalSince1970.rounded(.down))
        let expiresAtSeconds = Int64(expiresAt.timeIntervalSince1970.rounded(.down))
        return Data(
            [
                "offer",
                protocolVersion.rawValue.description,
                clientDeviceID.rawValue,
                clientSigningPublicKey.base64EncodedString(),
                hostDeviceID.rawValue,
                hostEphemeralPublicKey.base64EncodedString(),
                issuedAtSeconds.description,
                expiresAtSeconds.description,
            ].joined(separator: ":").utf8
        )
    }
}

public struct SecureSessionAcceptMessage: Codable, Equatable, Sendable {
    public var ephemeralPublicKey: Data
    public var signedAt: Date
    public var signature: Data

    public init(
        ephemeralPublicKey: Data,
        signedAt: Date,
        signature: Data
    ) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.signedAt = signedAt
        self.signature = signature
    }

    public static func signingPayload(
        clientDeviceID: DeviceID,
        clientSigningPublicKey: Data,
        hostDeviceID: DeviceID,
        hostEphemeralPublicKey: Data,
        hostOfferIssuedAt: Date,
        hostOfferExpiresAt: Date,
        clientEphemeralPublicKey: Data,
        signedAt: Date,
        protocolVersion: ProtocolVersion
    ) -> Data {
        let offerIssuedAtSeconds = Int64(hostOfferIssuedAt.timeIntervalSince1970.rounded(.down))
        let offerExpiresAtSeconds = Int64(hostOfferExpiresAt.timeIntervalSince1970.rounded(.down))
        let signedAtSeconds = Int64(signedAt.timeIntervalSince1970.rounded(.down))
        return Data(
            [
                "accept",
                protocolVersion.rawValue.description,
                clientDeviceID.rawValue,
                clientSigningPublicKey.base64EncodedString(),
                hostDeviceID.rawValue,
                hostEphemeralPublicKey.base64EncodedString(),
                offerIssuedAtSeconds.description,
                offerExpiresAtSeconds.description,
                clientEphemeralPublicKey.base64EncodedString(),
                signedAtSeconds.description,
            ].joined(separator: ":").utf8
        )
    }
}

public struct SecureSessionReadyMessage: Codable, Equatable, Sendable {
    public var establishedAt: Date
    public var hostIdentity: DeviceIdentity?
    public var connectionMode: HostConnectionMode?
    public var endpointKind: HostEndpointKind?
    public var previewAccessModes: [HostConnectionMode]?

    public init(
        establishedAt: Date,
        hostIdentity: DeviceIdentity? = nil,
        connectionMode: HostConnectionMode? = nil,
        endpointKind: HostEndpointKind? = nil,
        previewAccessModes: [HostConnectionMode]? = nil
    ) {
        self.establishedAt = establishedAt
        self.hostIdentity = hostIdentity
        self.connectionMode = connectionMode
        self.endpointKind = endpointKind
        self.previewAccessModes = previewAccessModes
    }
}

public struct AuthChallengeRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct AuthChallengeMessage: Codable, Equatable, Sendable {
    public var nonce: Data
    public var issuedAt: Date
    public var expiresAt: Date

    public init(nonce: Data, issuedAt: Date, expiresAt: Date) {
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct AuthProofMessage: Codable, Equatable, Sendable {
    public var deviceID: DeviceID
    public var challengeNonce: Data
    public var challengeIssuedAt: Date
    public var signedAt: Date
    public var protocolVersion: ProtocolVersion
    public var signature: Data

    public init(
        deviceID: DeviceID,
        challengeNonce: Data,
        challengeIssuedAt: Date,
        signedAt: Date,
        protocolVersion: ProtocolVersion,
        signature: Data
    ) {
        self.deviceID = deviceID
        self.challengeNonce = challengeNonce
        self.challengeIssuedAt = challengeIssuedAt
        self.signedAt = signedAt
        self.protocolVersion = protocolVersion
        self.signature = signature
    }

    public static func signingPayload(
        challengeNonce: Data,
        challengeIssuedAt: Date,
        deviceID: DeviceID,
        protocolVersion: ProtocolVersion,
        signedAt: Date
    ) -> Data {
        let challengeComponent = challengeNonce.base64EncodedString()
        let challengeIssuedAtSeconds = Int64(challengeIssuedAt.timeIntervalSince1970.rounded(.down))
        let signedAtSeconds = Int64(signedAt.timeIntervalSince1970.rounded(.down))
        return Data(
            "\(challengeComponent):\(challengeIssuedAtSeconds):\(deviceID.rawValue):\(protocolVersion.rawValue):\(signedAtSeconds)".utf8
        )
    }
}

public struct AuthResultMessage: Codable, Equatable, Sendable {
    public var status: AuthenticationStatus
    public var rejectionReason: String?

    public init(status: AuthenticationStatus, rejectionReason: String? = nil) {
        self.status = status
        self.rejectionReason = rejectionReason
    }
}

public struct PairRequestMessage: Codable, Equatable, Sendable {
    public var token: PairingToken
    public var device: DeviceIdentity
    public var publicKey: Data
    public var signature: Data

    public init(token: PairingToken, device: DeviceIdentity, publicKey: Data, signature: Data) {
        self.token = token
        self.device = device
        self.publicKey = publicKey
        self.signature = signature
    }
}

public struct PairResponseMessage: Codable, Equatable, Sendable {
    public var status: PairingStatus
    public var assignedDeviceID: DeviceID?
    public var rejectionReason: String?
    public var hostPublicKey: Data?

    public init(
        status: PairingStatus,
        assignedDeviceID: DeviceID?,
        rejectionReason: String?,
        hostPublicKey: Data? = nil
    ) {
        self.status = status
        self.assignedDeviceID = assignedDeviceID
        self.rejectionReason = rejectionReason
        self.hostPublicKey = hostPublicKey
    }
}

public struct ListSessionsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct SessionListMessage: Codable, Equatable, Sendable {
    public var sessions: [SessionSummary]

    public init(sessions: [SessionSummary]) {
        self.sessions = sessions
    }
}

public struct CreateSessionRequest: Codable, Equatable, Sendable {
    public var shellPath: String?
    public var workingDirectory: String?
    public var initialSize: SessionWindowSize

    public init(shellPath: String?, workingDirectory: String?, initialSize: SessionWindowSize) {
        self.shellPath = shellPath
        self.workingDirectory = workingDirectory
        self.initialSize = initialSize
    }
}

public struct RenameSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID
    public var title: String

    public init(sessionID: SessionID, title: String) {
        self.sessionID = sessionID
        self.title = title
    }
}

public struct CloseSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct AttachSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID
    public var lastObservedOutputSequence: UInt64?

    public init(sessionID: SessionID, lastObservedOutputSequence: UInt64?) {
        self.sessionID = sessionID
        self.lastObservedOutputSequence = lastObservedOutputSequence
    }
}

public struct DetachSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct ResizeSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID
    public var size: SessionWindowSize

    public init(sessionID: SessionID, size: SessionWindowSize) {
        self.sessionID = sessionID
        self.size = size
    }
}

public struct LockSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public enum ProtocolErrorCode: String, Codable, Sendable {
    case unsupportedVersion
    case malformedFrame
    case malformedMessage
    case unauthorized
    case forbidden
    case unsupportedOperation
    case pairingExpired
    case sessionNotFound
    case invalidState
    case rateLimited
    case internalFailure
}

public struct ProtocolErrorMessage: Codable, Equatable, Sendable {
    public var code: ProtocolErrorCode
    public var message: String
    public var isRetryable: Bool

    public init(code: ProtocolErrorCode, message: String, isRetryable: Bool) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
    }
}

public struct ControlEnvelope: Codable, Equatable, Sendable {
    public var id: MessageID
    public var replyTo: MessageID?
    public var message: ControlMessage

    public init(id: MessageID = .random(), replyTo: MessageID? = nil, message: ControlMessage) {
        self.id = id
        self.replyTo = replyTo
        self.message = message
    }
}

public enum ControlMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case secureSessionAccept(SecureSessionAcceptMessage)
    case secureSessionReady(SecureSessionReadyMessage)
    case authChallengeRequest(AuthChallengeRequest)
    case authChallenge(AuthChallengeMessage)
    case authProof(AuthProofMessage)
    case authResult(AuthResultMessage)
    case pairRequest(PairRequestMessage)
    case pairResponse(PairResponseMessage)
    case listSessions(ListSessionsRequest)
    case sessionList(SessionListMessage)
    case createSession(CreateSessionRequest)
    case renameSession(RenameSessionRequest)
    case closeSession(CloseSessionRequest)
    case attachSession(AttachSessionRequest)
    case detachSession(DetachSessionRequest)
    case resizeSession(ResizeSessionRequest)
    case lockSession(LockSessionRequest)
    case error(ProtocolErrorMessage)
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case hello
        case secureSessionAccept
        case secureSessionReady
        case authChallengeRequest
        case authChallenge
        case authProof
        case authResult
        case pairRequest
        case pairResponse
        case listSessions
        case sessionList
        case createSession
        case renameSession
        case closeSession
        case attachSession
        case detachSession
        case resizeSession
        case lockSession
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .hello:
            self = .hello(try container.decode(HelloMessage.self, forKey: .payload))
        case .secureSessionAccept:
            self = .secureSessionAccept(try container.decode(SecureSessionAcceptMessage.self, forKey: .payload))
        case .secureSessionReady:
            self = .secureSessionReady(try container.decode(SecureSessionReadyMessage.self, forKey: .payload))
        case .authChallengeRequest:
            self = .authChallengeRequest(try container.decode(AuthChallengeRequest.self, forKey: .payload))
        case .authChallenge:
            self = .authChallenge(try container.decode(AuthChallengeMessage.self, forKey: .payload))
        case .authProof:
            self = .authProof(try container.decode(AuthProofMessage.self, forKey: .payload))
        case .authResult:
            self = .authResult(try container.decode(AuthResultMessage.self, forKey: .payload))
        case .pairRequest:
            self = .pairRequest(try container.decode(PairRequestMessage.self, forKey: .payload))
        case .pairResponse:
            self = .pairResponse(try container.decode(PairResponseMessage.self, forKey: .payload))
        case .listSessions:
            self = .listSessions(try container.decode(ListSessionsRequest.self, forKey: .payload))
        case .sessionList:
            self = .sessionList(try container.decode(SessionListMessage.self, forKey: .payload))
        case .createSession:
            self = .createSession(try container.decode(CreateSessionRequest.self, forKey: .payload))
        case .renameSession:
            self = .renameSession(try container.decode(RenameSessionRequest.self, forKey: .payload))
        case .closeSession:
            self = .closeSession(try container.decode(CloseSessionRequest.self, forKey: .payload))
        case .attachSession:
            self = .attachSession(try container.decode(AttachSessionRequest.self, forKey: .payload))
        case .detachSession:
            self = .detachSession(try container.decode(DetachSessionRequest.self, forKey: .payload))
        case .resizeSession:
            self = .resizeSession(try container.decode(ResizeSessionRequest.self, forKey: .payload))
        case .lockSession:
            self = .lockSession(try container.decode(LockSessionRequest.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ProtocolErrorMessage.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .hello(message):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .secureSessionAccept(message):
            try container.encode(Kind.secureSessionAccept, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .secureSessionReady(message):
            try container.encode(Kind.secureSessionReady, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .authChallengeRequest(message):
            try container.encode(Kind.authChallengeRequest, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .authChallenge(message):
            try container.encode(Kind.authChallenge, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .authProof(message):
            try container.encode(Kind.authProof, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .authResult(message):
            try container.encode(Kind.authResult, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .pairRequest(message):
            try container.encode(Kind.pairRequest, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .pairResponse(message):
            try container.encode(Kind.pairResponse, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .listSessions(message):
            try container.encode(Kind.listSessions, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .sessionList(message):
            try container.encode(Kind.sessionList, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .createSession(message):
            try container.encode(Kind.createSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .renameSession(message):
            try container.encode(Kind.renameSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .closeSession(message):
            try container.encode(Kind.closeSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .attachSession(message):
            try container.encode(Kind.attachSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .detachSession(message):
            try container.encode(Kind.detachSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .resizeSession(message):
            try container.encode(Kind.resizeSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .lockSession(message):
            try container.encode(Kind.lockSession, forKey: .kind)
            try container.encode(message, forKey: .payload)
        case let .error(message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .payload)
        }
    }
}
