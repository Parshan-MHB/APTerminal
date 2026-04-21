import CryptoKit
import Foundation
import Network
import APTerminalProtocol
import APTerminalProtocolCodec
import APTerminalSecurity
import APTerminalTransport

public enum ClientConnectionError: Error, Equatable {
    case noConnection
    case timedOut
    case serviceUnavailable
    case networkFailure(String)
    case hostIdentityMismatch
    case missingHostPublicKey
    case unexpectedReply
    case protocolError(ProtocolErrorMessage)
}

public enum ClientConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(host: String, port: UInt16)
    case connected(host: DeviceIdentity, hostAddress: String, port: UInt16)
}

public actor ConnectionManager {
    public let deviceIdentity: DeviceIdentity

    private let privateKey: Curve25519.Signing.PrivateKey
    private let trustedHostRegistry: TrustedHostRegistry?
    private var framedConnection: FramedConnection?
    private var pendingReplies: [MessageID: CheckedContinuation<ControlEnvelope, Error>] = [:]
    private var outOfBandEnvelopes: [ControlEnvelope] = []
    private var connectionState: ClientConnectionState = .disconnected
    private var currentEndpoint: (host: String, port: UInt16)?
    private var currentExpectedHostPublicKey: Data?
    private var lastConnectedHostIdentity: DeviceIdentity?
    private var lastConnectionMode: HostConnectionMode = .lan
    private var lastEndpointKind: HostEndpointKind = .localNetwork
    private var activeSessionIDs = Set<SessionID>()
    private var lastConnectionError: ClientConnectionError?

    private let requestTimeoutNanoseconds: UInt64 = UInt64(
        APTerminalConfiguration.defaultRequestTimeoutSeconds * 1_000_000_000
    )

    public var onTerminalOutput: (@Sendable (TerminalStreamChunk) -> Void)?
    public var onConnectionStateChange: (@Sendable (ClientConnectionState) -> Void)?

    public init(
        deviceIdentity: DeviceIdentity,
        privateKey: Curve25519.Signing.PrivateKey = .init(),
        trustedHostRegistry: TrustedHostRegistry? = nil
    ) {
        self.deviceIdentity = deviceIdentity
        self.privateKey = privateKey
        self.trustedHostRegistry = trustedHostRegistry
    }

    public func connect(host: String, port: UInt16, expectedHostPublicKey: Data? = nil) async throws -> HelloMessage {
        connectionState = .connecting(host: host, port: port)
        onConnectionStateChange?(connectionState)

        let parameters = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let framed = FramedConnection(connection: connection, label: "com.apterminal.client.\(deviceIdentity.id.rawValue)")

        framed.onControlEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task {
                await self.handleControlEnvelope(envelope)
            }
        }

        framed.onTerminalOutputChunk = { [weak self] chunk in
            guard let self else { return }
            Task {
                await self.onTerminalOutput?(chunk)
            }
        }

        framed.onDisconnect = { [weak self] in
            guard let self else { return }
            Task {
                await self.handleDisconnect()
            }
        }

        framed.onError = { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleTransportError(error)
            }
        }

        framed.start()
        framedConnection = framed
        currentEndpoint = (host, port)
        currentExpectedHostPublicKey = expectedHostPublicKey
        lastConnectionError = nil

        let advertisedDeviceIdentity = DeviceIdentity(
            id: deviceIdentity.id,
            name: "",
            platform: deviceIdentity.platform,
            appVersion: ""
        )
        let helloReply = try await sendRequestAndAwaitReply(.hello(
            HelloMessage(
                role: .iosClient,
                device: advertisedDeviceIdentity,
                supportedVersions: [.current],
                signingPublicKey: privateKey.publicKey.rawRepresentation
            )
        ))

        switch helloReply.message {
        case let .hello(message):
            guard let hostPublicKey = message.signingPublicKey else {
                throw ClientConnectionError.missingHostPublicKey
            }

            let trustedHostRecord = await trustedHostRegistry?.record(for: message.device.id)
            let pinnedHostPublicKey = expectedHostPublicKey ?? trustedHostRecord?.publicKeyData

            if let pinnedHostPublicKey, pinnedHostPublicKey != hostPublicKey {
                throw ClientConnectionError.hostIdentityMismatch
            }

            let readyMessage = try await establishSecureSession(
                hello: message,
                hostPublicKey: hostPublicKey,
                pinnedHostPublicKey: pinnedHostPublicKey
            )
            var resolvedHello = message
            if let hostIdentity = readyMessage.hostIdentity {
                resolvedHello.device = hostIdentity
            }
            resolvedHello.connectionMode = readyMessage.connectionMode
            resolvedHello.endpointKind = readyMessage.endpointKind
            resolvedHello.previewAccessModes = readyMessage.previewAccessModes

            if let trustedHostRegistry, let existing = trustedHostRecord {
                try await authenticateIfNeeded(hostRecord: existing)
                try? await trustedHostRegistry.markSeen(
                    hostID: resolvedHello.device.id,
                    hostAddress: host,
                    port: port,
                    connectionMode: resolvedHello.connectionMode ?? .lan,
                    endpointKind: resolvedHello.endpointKind ?? .localNetwork
                )
            }

            lastConnectedHostIdentity = resolvedHello.device
            lastConnectionMode = resolvedHello.connectionMode ?? .lan
            lastEndpointKind = resolvedHello.endpointKind ?? .localNetwork
            connectionState = .connected(host: resolvedHello.device, hostAddress: host, port: port)
            onConnectionStateChange?(connectionState)
            return resolvedHello
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }
    }

    public func disconnect() {
        framedConnection?.cancel()
        framedConnection = nil
        connectionState = .disconnected
        onConnectionStateChange?(connectionState)
        for (_, continuation) in pendingReplies {
            continuation.resume(throwing: ClientConnectionError.noConnection)
        }
        pendingReplies.removeAll()
        activeSessionIDs.removeAll()
        currentEndpoint = nil
        currentExpectedHostPublicKey = nil
        lastConnectedHostIdentity = nil
        lastConnectionError = nil
        outOfBandEnvelopes.removeAll()
    }

    public func setTerminalOutputHandler(_ handler: (@Sendable (TerminalStreamChunk) -> Void)?) {
        onTerminalOutput = handler
    }

    public func setConnectionStateHandler(_ handler: (@Sendable (ClientConnectionState) -> Void)?) {
        onConnectionStateChange = handler
    }

    public func currentState() -> ClientConnectionState {
        connectionState
    }

    public func connect(using bootstrap: PairingBootstrapPayload) async throws -> HelloMessage {
        try await connect(host: bootstrap.host, port: bootstrap.port, expectedHostPublicKey: bootstrap.hostPublicKey)
    }

    public func pair(using token: PairingToken) async throws -> PairResponseMessage {
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: deviceIdentity.id)
        let signature = try privateKey.signature(for: payload)

        let reply = try await sendRequestAndAwaitReply(.pairRequest(
            PairRequestMessage(
                token: token,
                device: deviceIdentity,
                publicKey: privateKey.publicKey.rawRepresentation,
                signature: signature
            )
        ))

        switch reply.message {
        case let .pairResponse(message):
            if
                let trustedHostRegistry,
                let endpoint = currentEndpoint,
                case let .connected(hostIdentity, _, _) = connectionState,
                let hostPublicKey = message.hostPublicKey
            {
                try? await trustedHostRegistry.trust(
                    host: hostIdentity,
                    hostAddress: endpoint.host,
                    port: endpoint.port,
                    connectionMode: lastConnectionMode,
                    endpointKind: lastEndpointKind,
                    publicKeyData: hostPublicKey
                )
            }
            return message
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }
    }

    public func listSessions() async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.listSessions(.init()))
        return try extractSessionList(from: reply)
    }

    public func createSession(shellPath: String?, workingDirectory: String?, size: SessionWindowSize) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(
            .createSession(
                CreateSessionRequest(shellPath: shellPath, workingDirectory: workingDirectory, initialSize: size)
            )
        )
        return try extractSessionList(from: reply)
    }

    public func renameSession(id: SessionID, title: String) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.renameSession(.init(sessionID: id, title: title)))
        return try extractSessionList(from: reply)
    }

    public func closeSession(id: SessionID) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.closeSession(.init(sessionID: id)))
        activeSessionIDs.remove(id)
        return try extractSessionList(from: reply)
    }

    public func attachSession(id: SessionID, lastObservedOutputSequence: UInt64? = nil) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(
            .attachSession(.init(sessionID: id, lastObservedOutputSequence: lastObservedOutputSequence))
        )
        activeSessionIDs.insert(id)
        return try extractSessionList(from: reply)
    }

    public func detachSession(id: SessionID) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.detachSession(.init(sessionID: id)))
        activeSessionIDs.remove(id)
        return try extractSessionList(from: reply)
    }

    public func resizeSession(id: SessionID, size: SessionWindowSize) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.resizeSession(.init(sessionID: id, size: size)))
        return try extractSessionList(from: reply)
    }

    public func lockSession(id: SessionID) async throws -> [SessionSummary] {
        let reply = try await sendRequestAndAwaitReply(.lockSession(.init(sessionID: id)))
        activeSessionIDs.remove(id)
        return try extractSessionList(from: reply)
    }

    public func sendInput(sessionID: SessionID, data: Data, sequenceNumber: UInt64 = 0) async throws {
        guard let framedConnection else {
            throw ClientConnectionError.noConnection
        }

        let chunk = TerminalStreamChunk(
            sessionID: sessionID,
            direction: .input,
            sequenceNumber: sequenceNumber,
            data: data
        )

        try await framedConnection.sendTerminalChunk(chunk, kind: .terminalInput)
    }

    public func reconnect() async throws -> HelloMessage {
        guard let endpoint = currentEndpoint else {
            throw ClientConnectionError.noConnection
        }

        let expectedHostPublicKey = await trustedHostPublicKeyForReconnect()

        let hello = try await connect(host: endpoint.host, port: endpoint.port, expectedHostPublicKey: expectedHostPublicKey)

        for sessionID in activeSessionIDs {
            _ = try await attachSession(id: sessionID)
        }

        return hello
    }

    private func sendRequestAndAwaitReply(_ message: ControlMessage) async throws -> ControlEnvelope {
        guard let framedConnection else {
            throw ClientConnectionError.noConnection
        }

        let envelope = ControlEnvelope(message: message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingReplies[envelope.id] = continuation

            Task {
                try? await Task.sleep(nanoseconds: self.requestTimeoutNanoseconds)
                self.timeoutPendingRequest(id: envelope.id)
            }

            Task {
                do {
                    try await framedConnection.sendControlEnvelope(envelope)
                } catch {
                    self.resumePending(id: envelope.id, with: .failure(error))
                }
            }
        }
    }

    private func handleControlEnvelope(_ envelope: ControlEnvelope) {
        guard let replyTo = envelope.replyTo else {
            outOfBandEnvelopes.append(envelope)
            return
        }

        guard let continuation = pendingReplies.removeValue(forKey: replyTo) else {
            outOfBandEnvelopes.append(envelope)
            return
        }

        continuation.resume(returning: envelope)
    }

    private func resumePending(id: MessageID, with result: Result<ControlEnvelope, Error>) {
        guard let continuation = pendingReplies.removeValue(forKey: id) else {
            return
        }

        continuation.resume(with: result)
    }

    private func extractSessionList(from envelope: ControlEnvelope) throws -> [SessionSummary] {
        switch envelope.message {
        case let .sessionList(message):
            return message.sessions
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }
    }

    private func handleDisconnect() {
        connectionState = .disconnected
        onConnectionStateChange?(connectionState)
        let disconnectError = lastConnectionError ?? .noConnection
        for (_, continuation) in pendingReplies {
            continuation.resume(throwing: disconnectError)
        }
        pendingReplies.removeAll()
        outOfBandEnvelopes.removeAll()
        framedConnection = nil
        lastConnectionError = nil
    }

    private func trustedHostPublicKeyForReconnect() async -> Data? {
        if let currentExpectedHostPublicKey {
            return currentExpectedHostPublicKey
        }

        guard let trustedHostRegistry, let hostIdentity = lastConnectedHostIdentity else {
            return nil
        }

        return await trustedHostRegistry.record(for: hostIdentity.id)?.publicKeyData
    }

    private func timeoutPendingRequest(id: MessageID) {
        guard pendingReplies[id] != nil else {
            return
        }

        lastConnectionError = .timedOut
        resumePending(id: id, with: .failure(ClientConnectionError.timedOut))
    }

    private func handleTransportError(_ error: Error) {
        lastConnectionError = mapTransportError(error)
    }

    private func authenticateIfNeeded(
        hostRecord: TrustedHostRecord
    ) async throws {
        guard hostRecord.publicKeyData == currentExpectedHostPublicKey ?? hostRecord.publicKeyData else {
            throw ClientConnectionError.hostIdentityMismatch
        }

        let challengeReply = try await sendRequestAndAwaitReply(.authChallengeRequest(.init()))
        let challenge: AuthChallengeMessage
        switch challengeReply.message {
        case let .authChallenge(message):
            challenge = message
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }

        let signedAt = Date()
        let payload = AuthProofMessage.signingPayload(
            challengeNonce: challenge.nonce,
            challengeIssuedAt: challenge.issuedAt,
            deviceID: deviceIdentity.id,
            protocolVersion: .current,
            signedAt: signedAt
        )
        let signature = try privateKey.signature(for: payload)
        let proof = AuthProofMessage(
            deviceID: deviceIdentity.id,
            challengeNonce: challenge.nonce,
            challengeIssuedAt: challenge.issuedAt,
            signedAt: signedAt,
            protocolVersion: .current,
            signature: signature
        )

        let reply = try await sendRequestAndAwaitReply(.authProof(proof))

        switch reply.message {
        case let .authResult(result):
            guard result.status == .accepted else {
                throw ClientConnectionError.protocolError(
                    ProtocolErrorMessage(
                        code: .unauthorized,
                        message: result.rejectionReason ?? "Authentication proof rejected",
                        isRetryable: false
                    )
                )
            }
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }
    }

    private func establishSecureSession(
        hello: HelloMessage,
        hostPublicKey: Data,
        pinnedHostPublicKey: Data?
    ) async throws -> SecureSessionReadyMessage {
        guard let offer = hello.secureSessionOffer else {
            throw ClientConnectionError.unexpectedReply
        }

        if let pinnedHostPublicKey, pinnedHostPublicKey != hostPublicKey {
            throw ClientConnectionError.hostIdentityMismatch
        }

        guard Date() < offer.expiresAt else {
            throw ClientConnectionError.timedOut
        }

        let offerPayload = SecureSessionOfferMessage.signingPayload(
            clientDeviceID: deviceIdentity.id,
            clientSigningPublicKey: privateKey.publicKey.rawRepresentation,
            hostDeviceID: hello.device.id,
            hostEphemeralPublicKey: offer.ephemeralPublicKey,
            issuedAt: offer.issuedAt,
            expiresAt: offer.expiresAt,
            protocolVersion: .current
        )
        let hostSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: hostPublicKey)
        guard hostSigningKey.isValidSignature(offer.signature, for: offerPayload) else {
            throw ClientConnectionError.hostIdentityMismatch
        }

        let clientEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientEphemeralPublicKey = clientEphemeralPrivateKey.publicKey.rawRepresentation
        let signedAt = Date()
        let acceptPayload = SecureSessionAcceptMessage.signingPayload(
            clientDeviceID: deviceIdentity.id,
            clientSigningPublicKey: privateKey.publicKey.rawRepresentation,
            hostDeviceID: hello.device.id,
            hostEphemeralPublicKey: offer.ephemeralPublicKey,
            hostOfferIssuedAt: offer.issuedAt,
            hostOfferExpiresAt: offer.expiresAt,
            clientEphemeralPublicKey: clientEphemeralPublicKey,
            signedAt: signedAt,
            protocolVersion: .current
        )
        let signature = try privateKey.signature(for: acceptPayload)
        let accept = SecureSessionAcceptMessage(
            ephemeralPublicKey: clientEphemeralPublicKey,
            signedAt: signedAt,
            signature: signature
        )

        guard let framedConnection else {
            throw ClientConnectionError.noConnection
        }

        try await framedConnection.sendControlEnvelope(.init(message: .secureSessionAccept(accept)))

        let hostEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: offer.ephemeralPublicKey)
        let sharedSecret = try clientEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: hostEphemeralKey)
        let transcript = acceptPayload + offer.signature
        let sessionKeys = SecureSessionKeyDerivation.deriveKeys(
            sharedSecret: sharedSecret,
            transcript: transcript,
            role: .client
        )
        framedConnection.activateSecureSession(keys: sessionKeys)

        let readyReply = try await nextSecureSessionReply()
        switch readyReply.message {
        case let .secureSessionReady(message):
            return message
        case let .error(error):
            throw ClientConnectionError.protocolError(error)
        default:
            throw ClientConnectionError.unexpectedReply
        }
    }

    private func nextSecureSessionReply() async throws -> ControlEnvelope {
        try await withThrowingTaskGroup(of: ControlEnvelope.self) { group in
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    if let envelope = await self.dequeueOutOfBandEnvelope() {
                        return envelope
                    }
                    try await Task.sleep(
                        for: .milliseconds(APTerminalConfiguration.defaultSecureSessionReplyPollIntervalMilliseconds)
                    )
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.requestTimeoutNanoseconds)
                throw ClientConnectionError.timedOut
            }

            let envelope = try await group.next()!
            group.cancelAll()
            return envelope
        }
    }

    private func dequeueOutOfBandEnvelope() -> ControlEnvelope? {
        guard outOfBandEnvelopes.isEmpty == false else {
            return nil
        }

        return outOfBandEnvelopes.removeFirst()
    }

    private func mapTransportError(_ error: Error) -> ClientConnectionError {
        if let connectionError = error as? ClientConnectionError {
            return connectionError
        }

        if let framedError = error as? FramedConnectionError {
            switch framedError {
            case .disconnected:
                return .noConnection
            case .idleTimeout:
                return .timedOut
            case let .outboundBackpressureExceeded(limit):
                return .networkFailure("backpressure:\(limit)")
            case let .secureTransportFailed(description):
                return .networkFailure("secure:\(description)")
            }
        }

        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                switch code {
                case .ETIMEDOUT:
                    return .timedOut
                case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EADDRNOTAVAIL:
                    return .serviceUnavailable
                default:
                    return .networkFailure(code.rawValue.description)
                }
            case let .dns(code):
                return .networkFailure("dns:\(code)")
            case .tls:
                return .networkFailure("tls")
            default:
                return .networkFailure("unknown")
            }
        }

        let nsError = error as NSError
        return .networkFailure("\(nsError.domain):\(nsError.code)")
    }
}
