import Foundation
import Network
import CryptoKit
import APTerminalCore
import APTerminalProtocol
import APTerminalProtocolCodec
import APTerminalTransport

public final class HostServer: @unchecked Sendable {
    public private(set) var port: NWEndpoint.Port?
    public var listenerState: NWListener.State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _listenerState
    }
    public var isAdvertisingBonjour: Bool {
        listener.service != nil
    }

    private let runtime: HostRuntime
    private let listener: NWListener
    private let connectionConfiguration: FramedConnectionConfiguration
    private let advertiseBonjour: Bool
    private let logger = StructuredLogger(subsystem: "com.apterminal", category: "HostServer")
    private let queue = DispatchQueue(label: "com.apterminal.host.listener")
    private let stateLock = NSLock()
    private var _listenerState: NWListener.State = .setup
    private var stopRequested = false
    private var peers: [UUID: HostPeerConnection] = [:]

    public init(
        runtime: HostRuntime,
        port: UInt16 = 0,
        bindHost: String? = nil,
        advertiseBonjour: Bool = true,
        connectionConfiguration: FramedConnectionConfiguration = .init()
    ) throws {
        self.runtime = runtime
        self.connectionConfiguration = connectionConfiguration
        self.advertiseBonjour = advertiseBonjour

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false

        if let bindHost {
            let resolvedPort = NWEndpoint.Port(rawValue: port) ?? .any
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: resolvedPort)
            self.listener = try NWListener(using: parameters)
        } else {
            let nwPort = port == 0 ? nil : NWEndpoint.Port(rawValue: port)
            if let nwPort {
                self.listener = try NWListener(using: parameters, on: nwPort)
            } else {
                self.listener = try NWListener(using: parameters)
            }
        }
    }

    public func start() {
        listener.service = advertiseBonjour
            ? NWListener.Service(name: BonjourConstants.serviceName, type: BonjourConstants.serviceType)
            : nil
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.stateLock.lock()
            let stopRequested = self.stopRequested
            if stopRequested,
               case .ready = state {
                self.stateLock.unlock()
                return
            }
            self._listenerState = state
            if case .cancelled = state {
                self.port = nil
            } else if case .failed = state {
                self.port = nil
            }
            self.stateLock.unlock()
            self.logger.info(
                "Listener state changed",
                metadata: [
                    "state": String(describing: state),
                ]
            )
            if case .ready = state, stopRequested == false {
                self.port = self.listener.port
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peerID = UUID()
            let peer = HostPeerConnection(
                id: peerID,
                connection: connection,
                runtime: self.runtime,
                connectionConfiguration: self.connectionConfiguration
            ) { [weak self] id in
                self?.peers.removeValue(forKey: id)
            }
            self.peers[peerID] = peer
            peer.start()
        }

        listener.start(queue: queue)
    }

    public func stop() {
        let peersToStop: [HostPeerConnection]
        let peerCount: Int
        stateLock.lock()
        if stopRequested {
            stateLock.unlock()
            return
        }
        stopRequested = true
        _listenerState = .cancelled
        port = nil
        peersToStop = Array(peers.values)
        peerCount = peersToStop.count
        peers.removeAll()
        stateLock.unlock()

        logger.notice("Stopping host listener", metadata: ["peerCount": "\(peerCount)"])
        listener.service = nil
        peersToStop.forEach { $0.stop() }
        listener.cancel()
    }

    public func disconnectAuthenticatedDevice(_ deviceID: DeviceID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.peers.values.forEach { peer in
                peer.stopIfAuthenticated(deviceID: deviceID)
            }
        }
    }

    public func disconnectAllPeers() {
        queue.async { [weak self] in
            guard let self else { return }
            self.peers.values.forEach { $0.stop() }
            self.peers.removeAll()
        }
    }
}

private enum HostPeerAuthState {
    case awaitingHello
    case untrusted(DeviceIdentity)
    case authenticated(DeviceIdentity)
}

private struct PendingAuthChallenge {
    let message: AuthChallengeMessage
    let deviceID: DeviceID
}

private struct PendingSecureSessionOffer {
    let message: SecureSessionOfferMessage
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let clientDevice: DeviceIdentity
    let clientSigningPublicKey: Data
}

private actor PeerRequestRateLimiter {
    enum Bucket {
        case hello
        case pairRequest
        case sessionControl
        case createSession
        case attachSession
    }

    private struct WindowState {
        var timestamps: [Date] = []
    }

    private var windows: [Bucket: WindowState] = [:]
    private let windowLength: TimeInterval = APTerminalConfiguration.defaultRateLimitWindowSeconds

    func allow(_ bucket: Bucket) -> Bool {
        let now = Date()
        var state = windows[bucket] ?? WindowState()
        state.timestamps.removeAll { now.timeIntervalSince($0) > windowLength }

        let limit: Int
        switch bucket {
        case .hello:
            limit = APTerminalConfiguration.defaultHelloRateLimit
        case .pairRequest:
            limit = APTerminalConfiguration.defaultPairRateLimit
        case .sessionControl:
            limit = APTerminalConfiguration.defaultSessionControlRateLimit
        case .createSession:
            limit = APTerminalConfiguration.defaultCreateSessionRateLimit
        case .attachSession:
            limit = APTerminalConfiguration.defaultAttachSessionRateLimit
        }

        guard state.timestamps.count < limit else {
            windows[bucket] = state
            return false
        }

        state.timestamps.append(now)
        windows[bucket] = state
        return true
    }
}

private final class HostPeerConnection: @unchecked Sendable {
    private let id: UUID
    private let framedConnection: FramedConnection
    private let runtime: HostRuntime
    private let onStop: @Sendable (UUID) -> Void
    private let logger: StructuredLogger

    private var authState: HostPeerAuthState = .awaitingHello
    private var secureSessionEstablished = false
    private var pendingSecureSessionOffer: PendingSecureSessionOffer?
    private var secureSessionClientSigningPublicKey: Data?
    private var pendingAuthChallenge: PendingAuthChallenge?
    private var consumedChallengeNonces = Set<Data>()
    private var attachedSessions = Set<SessionID>()
    private let rateLimiter = PeerRequestRateLimiter()

    init(
        id: UUID,
        connection: NWConnection,
        runtime: HostRuntime,
        connectionConfiguration: FramedConnectionConfiguration,
        onStop: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.runtime = runtime
        self.onStop = onStop
        self.logger = StructuredLogger(
            subsystem: "com.apterminal",
            category: "HostPeerConnection"
        )
        self.framedConnection = FramedConnection(
            connection: connection,
            label: "com.apterminal.host.peer.\(id.uuidString)",
            configuration: connectionConfiguration
        )
    }

    func start() {
        logger.info("Starting peer connection", metadata: ["peerID": id.uuidString])
        framedConnection.onControlEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task {
                await self.handleControlEnvelope(envelope)
            }
        }

        framedConnection.onTerminalInputChunk = { [weak self] chunk in
            guard let self else { return }
            Task {
                await self.handleTerminalInput(chunk)
            }
        }

        framedConnection.onDisconnect = { [weak self] in
            self?.stop()
        }

        framedConnection.onError = { [logger] error in
            let description = String(describing: error)
            if error is FrameStreamAccumulatorError || error is FrameCodecError {
                logger.error(
                    "Closing peer after malformed or oversized frame",
                    metadata: ["error": description]
                )
            } else {
                logger.error(
                    "Peer transport error",
                    metadata: ["error": description]
                )
            }
        }

        framedConnection.start()
    }

    func stop() {
        logger.notice(
            "Stopping peer connection",
            metadata: [
                "peerID": id.uuidString,
                "attachedSessionCount": "\(attachedSessions.count)",
            ]
        )
        let sessionsToDetach = attachedSessions
        attachedSessions.removeAll()

        Task {
            for sessionID in sessionsToDetach {
                await runtime.detach(sessionID: sessionID, consumerID: id)
            }
        }

        framedConnection.cancel()
        onStop(id)
    }

    private func handleControlEnvelope(_ envelope: ControlEnvelope) async {
        switch envelope.message {
        case let .hello(message):
            guard await rateLimiter.allow(.hello) else {
                await handleRateLimitExceeded(kind: "hello")
                return
            }
            await handleHello(message, envelopeID: envelope.id)
        case let .secureSessionAccept(message):
            await handleSecureSessionAccept(message, envelopeID: envelope.id)
        case .authChallengeRequest:
            guard secureSessionEstablished else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }
            await handleAuthChallengeRequest(envelopeID: envelope.id)
        case .authChallenge:
            await sendError(.forbidden, "Unexpected client message", replyTo: envelope.id)
        case let .authProof(message):
            guard secureSessionEstablished else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }
            await handleAuthProof(message, envelopeID: envelope.id)
        case let .pairRequest(message):
            guard await rateLimiter.allow(.pairRequest) else {
                await handleRateLimitExceeded(kind: "pairRequest")
                return
            }
            guard secureSessionEstablished else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }
            await handlePairRequest(message, envelopeID: envelope.id)
        case .listSessions:
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "listSessions")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }
            await replySessionList(replyTo: envelope.id)
        case let .createSession(message):
            guard await rateLimiter.allow(.sessionControl), await rateLimiter.allow(.createSession) else {
                await handleRateLimitExceeded(kind: "createSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            do {
                let requestingDeviceID = authenticatedDeviceID()
                let response = try await runtime.createSession(message, requestedBy: requestingDeviceID)
                try await framedConnection.sendControlEnvelope(.init(replyTo: envelope.id, message: .sessionList(response)))
            } catch HostSessionLaunchPolicyError.shellPathNotAllowed {
                await sendError(.forbidden, "Session launch request rejected", replyTo: envelope.id)
            } catch HostSessionLaunchPolicyError.workingDirectoryNotAllowed {
                await sendError(.forbidden, "Session launch request rejected", replyTo: envelope.id)
            } catch {
                await sendError(.internalFailure, "Failed to create session", replyTo: envelope.id)
            }
        case let .renameSession(message):
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "renameSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            do {
                let response = try await runtime.renameSession(message, requestedBy: authenticatedDeviceID())
                try await framedConnection.sendControlEnvelope(.init(replyTo: envelope.id, message: .sessionList(response)))
            } catch SessionManagerError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.unsupportedOperation {
                await sendError(.unsupportedOperation, "This session is read-only and cannot be renamed", replyTo: envelope.id)
            } catch SessionManagerError.invalidTitle {
                await sendError(.invalidState, "Session title cannot be empty", replyTo: envelope.id)
            } catch {
                await sendError(.internalFailure, "Failed to rename session", replyTo: envelope.id)
            }
        case let .closeSession(message):
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "closeSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            do {
                let response = try await runtime.closeSession(message, requestedBy: authenticatedDeviceID())
                try await framedConnection.sendControlEnvelope(.init(replyTo: envelope.id, message: .sessionList(response)))
            } catch SessionManagerError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.unsupportedOperation {
                await sendError(.unsupportedOperation, "This session is exposed as a read-only preview", replyTo: envelope.id)
            } catch {
                await sendError(.internalFailure, "Failed to close session", replyTo: envelope.id)
            }
        case let .attachSession(message):
            guard await rateLimiter.allow(.sessionControl), await rateLimiter.allow(.attachSession) else {
                await handleRateLimitExceeded(kind: "attachSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            do {
                try await runtime.attach(
                    sessionID: message.sessionID,
                    consumerID: id,
                    requestedBy: authenticatedDeviceID()
                ) { [weak self] chunk in
                    guard let self else { return }
                    Task {
                        do {
                            try await self.framedConnection.sendTerminalChunk(chunk, kind: .terminalOutput)
                        } catch FramedConnectionError.outboundBackpressureExceeded {
                            self.logger.error(
                                "Closing peer after outbound backpressure overflow",
                                metadata: [
                                    "peerID": self.id.uuidString,
                                    "sessionID": message.sessionID.rawValue,
                                ]
                            )
                            self.stop()
                        } catch {
                            self.logger.error(
                                "Failed to forward terminal output",
                                metadata: [
                                    "peerID": self.id.uuidString,
                                    "sessionID": message.sessionID.rawValue,
                                    "error": String(describing: error),
                                ]
                            )
                        }
                    }
                }
                attachedSessions.insert(message.sessionID)
                await replySessionList(replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.previewAccessDenied {
                await sendError(.forbidden, "Preview access denied", replyTo: envelope.id)
            } catch {
                await sendError(.internalFailure, "Failed to attach session: \((error as NSError).localizedDescription)", replyTo: envelope.id)
            }
        case let .detachSession(message):
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "detachSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            attachedSessions.remove(message.sessionID)
            await runtime.detach(sessionID: message.sessionID, consumerID: id)
            await replySessionList(replyTo: envelope.id)
        case let .resizeSession(message):
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "resizeSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            do {
                let response = try await runtime.resizeSession(message, requestedBy: authenticatedDeviceID())
                try await framedConnection.sendControlEnvelope(.init(replyTo: envelope.id, message: .sessionList(response)))
            } catch SessionManagerError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.sessionNotFound {
                await sendError(.sessionNotFound, "Session no longer exists", replyTo: envelope.id)
            } catch ExternalTerminalSessionProviderError.unsupportedOperation {
                await sendError(.unsupportedOperation, "This session cannot be resized from the phone", replyTo: envelope.id)
            } catch SessionManagerError.sessionExited {
                await sendError(.invalidState, "Exited sessions cannot be resized", replyTo: envelope.id)
            } catch {
                await sendError(.internalFailure, "Failed to resize session", replyTo: envelope.id)
            }
        case let .lockSession(message):
            guard await rateLimiter.allow(.sessionControl) else {
                await handleRateLimitExceeded(kind: "lockSession")
                return
            }
            guard case .authenticated = authState else {
                await sendUnauthorized(replyTo: envelope.id)
                return
            }

            attachedSessions.remove(message.sessionID)
            await runtime.lockSession(message)
            await replySessionList(replyTo: envelope.id)
        case .secureSessionReady, .pairResponse, .authResult, .sessionList, .error:
            await sendError(.forbidden, "Unexpected client message", replyTo: envelope.id)
        }
    }

    private func handleTerminalInput(_ chunk: TerminalStreamChunk) async {
        guard secureSessionEstablished, case .authenticated = authState else {
            return
        }

        do {
            try await runtime.sendInput(chunk)
        } catch SessionManagerError.sessionNotFound {
            await sendError(.sessionNotFound, "Session no longer exists", replyTo: nil)
        } catch ExternalTerminalSessionProviderError.sessionNotFound {
            await sendError(.sessionNotFound, "Session no longer exists", replyTo: nil)
        } catch ExternalTerminalSessionProviderError.unsupportedOperation {
            await sendError(.unsupportedOperation, "This session is read-only and does not accept input", replyTo: nil)
        } catch SessionManagerError.sessionExited {
            await sendError(.invalidState, "Exited sessions do not accept input", replyTo: nil)
        } catch {
            await sendError(.sessionNotFound, "Failed to deliver terminal input", replyTo: nil)
        }
    }

    private func handleHello(_ message: HelloMessage, envelopeID: MessageID) async {
        guard let clientSigningPublicKey = message.signingPublicKey else {
            await runtime.logSecureSessionFailure(deviceID: message.device.id, note: "Client signing key missing from hello")
            await sendError(.malformedMessage, "Client signing key required", replyTo: envelopeID)
            stopSoon()
            return
        }

        let issuedAt = Date()
        let expiresAt = issuedAt.addingTimeInterval(runtime.secureSessionOfferLifetimeSeconds)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation
        let offerPayload = SecureSessionOfferMessage.signingPayload(
            clientDeviceID: message.device.id,
            clientSigningPublicKey: clientSigningPublicKey,
            hostDeviceID: runtime.hostIdentity.id,
            hostEphemeralPublicKey: ephemeralPublicKey,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            protocolVersion: .current
        )
        let signature: Data
        do {
            signature = try await runtime.hostSigningPrivateKeySignature(for: offerPayload)
        } catch {
            await runtime.logSecureSessionFailure(deviceID: message.device.id, note: "Host failed to sign secure session offer")
            await sendError(.internalFailure, "Failed to prepare secure session", replyTo: envelopeID)
            stopSoon()
            return
        }

        let offer = SecureSessionOfferMessage(
            ephemeralPublicKey: ephemeralPublicKey,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: signature
        )

        pendingSecureSessionOffer = PendingSecureSessionOffer(
            message: offer,
            privateKey: ephemeralPrivateKey,
            clientDevice: message.device,
            clientSigningPublicKey: clientSigningPublicKey
        )
        pendingAuthChallenge = nil
        consumedChallengeNonces.removeAll()
        secureSessionEstablished = false
        secureSessionClientSigningPublicKey = nil
        authState = .untrusted(message.device)

        let advertisedHostIdentity = DeviceIdentity(
            id: runtime.hostIdentity.id,
            name: "",
            platform: runtime.hostIdentity.platform,
            appVersion: ""
        )
        let response = HelloMessage(
            role: .macCompanion,
            device: advertisedHostIdentity,
            supportedVersions: [.current],
            signingPublicKey: runtime.hostSigningPublicKey,
            authChallenge: nil,
            secureSessionOffer: offer,
            connectionMode: nil,
            endpointKind: nil,
            previewAccessModes: nil
        )

        try? await framedConnection.sendControlEnvelope(.init(replyTo: envelopeID, message: .hello(response)))
    }

    private func handleSecureSessionAccept(_ message: SecureSessionAcceptMessage, envelopeID: MessageID) async {
        guard case let .untrusted(identity) = authState,
              let pendingSecureSessionOffer
        else {
            await runtime.logSecureSessionFailure(deviceID: authenticatedDeviceID(), note: "Unexpected secure session accept")
            await sendUnauthorized(replyTo: envelopeID)
            return
        }

        guard Date() < pendingSecureSessionOffer.message.expiresAt else {
            await runtime.logSecureSessionFailure(deviceID: identity.id, note: "Secure session offer expired")
            await sendError(.unauthorized, "Secure session offer expired", replyTo: envelopeID)
            stopSoon()
            return
        }

        if let trustedRecord = await runtime.trustedDeviceRecord(for: identity.id),
           trustedRecord.publicKeyData != pendingSecureSessionOffer.clientSigningPublicKey {
            await runtime.logSecureSessionFailure(deviceID: identity.id, note: "Secure session signing key mismatch")
            await sendError(.unauthorized, "Secure session proof rejected", replyTo: envelopeID)
            stopSoon()
            return
        }

        let acceptPayload = SecureSessionAcceptMessage.signingPayload(
            clientDeviceID: identity.id,
            clientSigningPublicKey: pendingSecureSessionOffer.clientSigningPublicKey,
            hostDeviceID: runtime.hostIdentity.id,
            hostEphemeralPublicKey: pendingSecureSessionOffer.message.ephemeralPublicKey,
            hostOfferIssuedAt: pendingSecureSessionOffer.message.issuedAt,
            hostOfferExpiresAt: pendingSecureSessionOffer.message.expiresAt,
            clientEphemeralPublicKey: message.ephemeralPublicKey,
            signedAt: message.signedAt,
            protocolVersion: .current
        )

        do {
            let clientSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: pendingSecureSessionOffer.clientSigningPublicKey)
            guard clientSigningKey.isValidSignature(message.signature, for: acceptPayload) else {
                throw HostAuthenticationError.invalidSignature
            }

            let clientEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ephemeralPublicKey)
            let sharedSecret = try pendingSecureSessionOffer.privateKey.sharedSecretFromKeyAgreement(with: clientEphemeralKey)
            let transcript = acceptPayload + pendingSecureSessionOffer.message.signature
            let sessionKeys = SecureSessionKeyDerivation.deriveKeys(
                sharedSecret: sharedSecret,
                transcript: transcript,
                role: .server
            )

            framedConnection.activateSecureSession(keys: sessionKeys)
            secureSessionEstablished = true
            secureSessionClientSigningPublicKey = pendingSecureSessionOffer.clientSigningPublicKey
            try await framedConnection.sendControlEnvelope(
                .init(
                    replyTo: envelopeID,
                    message: .secureSessionReady(
                        .init(
                            establishedAt: Date(),
                            hostIdentity: runtime.hostIdentity,
                            connectionMode: runtime.connectionMode,
                            endpointKind: runtime.bootstrapEndpointKind,
                            previewAccessModes: await runtime.previewAccessModes(for: identity.id)
                        )
                    )
                )
            )
        } catch {
            await runtime.logSecureSessionFailure(deviceID: identity.id, note: "Secure session proof rejected")
            await sendError(.unauthorized, "Secure session proof rejected", replyTo: envelopeID)
            stopSoon()
            return
        }

        self.pendingSecureSessionOffer = nil
    }

    private func handleAuthChallengeRequest(envelopeID: MessageID) async {
        guard case let .untrusted(identity) = authState else {
            await sendUnauthorized(replyTo: envelopeID)
            return
        }

        let challenge = await runtime.makeAuthChallenge()
        pendingAuthChallenge = PendingAuthChallenge(
            message: challenge,
            deviceID: identity.id
        )
        consumedChallengeNonces.removeAll()
        await runtime.logAuthChallengeIssued(deviceID: identity.id)
        try? await framedConnection.sendControlEnvelope(.init(replyTo: envelopeID, message: .authChallenge(challenge)))
    }

    private func handleAuthProof(_ message: AuthProofMessage, envelopeID: MessageID) async {
        if consumedChallengeNonces.contains(message.challengeNonce) {
            try? await framedConnection.sendControlEnvelope(
                .init(
                    replyTo: envelopeID,
                    message: .authResult(.init(status: .replayed, rejectionReason: "Authentication proof rejected"))
                )
            )
            stopSoon()
            return
        }

        guard case let .untrusted(identity) = authState else {
            await sendUnauthorized(replyTo: envelopeID)
            return
        }

        guard let pendingAuthChallenge else {
            await sendUnauthorized(replyTo: envelopeID)
            return
        }

        consumedChallengeNonces.insert(message.challengeNonce)

        let result = await runtime.authenticate(
            message,
            challenge: pendingAuthChallenge.message,
            expectedDeviceID: identity.id
        )

        switch result {
        case .success:
            authState = .authenticated(identity)
            try? await framedConnection.sendControlEnvelope(
                .init(replyTo: envelopeID, message: .authResult(.init(status: .accepted)))
            )
        case let .failure(error):
            let status: AuthenticationStatus
            switch error {
            case .challengeExpired, .proofExpired:
                status = .stale
            case .challengeMismatch:
                status = .replayed
            case .deviceMismatch, .trustedDeviceMissing, .invalidSignature:
                status = .rejected
            }

            try? await framedConnection.sendControlEnvelope(
                .init(
                    replyTo: envelopeID,
                    message: .authResult(.init(status: status, rejectionReason: "Authentication proof rejected"))
                )
            )
            stopSoon()
        }
    }

    private func handlePairRequest(_ message: PairRequestMessage, envelopeID: MessageID) async {
        if case let .authenticated(device) = authState, device.id == message.device.id {
            let response = PairResponseMessage(
                status: .accepted,
                assignedDeviceID: message.device.id,
                rejectionReason: nil,
                hostPublicKey: runtime.hostSigningPublicKey
            )
            try? await framedConnection.sendControlEnvelope(.init(replyTo: envelopeID, message: .pairResponse(response)))
            return
        }

        guard case let .untrusted(helloIdentity) = authState, helloIdentity.id == message.device.id else {
            await sendUnauthorized(replyTo: envelopeID)
            return
        }

        guard secureSessionClientSigningPublicKey == message.publicKey else {
            await runtime.logDenied(deviceID: message.device.id, note: "Pairing key mismatch")
            let response = PairResponseMessage(
                status: .rejected,
                assignedDeviceID: nil,
                rejectionReason: "Pairing request rejected",
                hostPublicKey: runtime.hostSigningPublicKey
            )
            try? await framedConnection.sendControlEnvelope(.init(replyTo: envelopeID, message: .pairResponse(response)))
            stopSoon()
            return
        }

        let response = await runtime.pair(message)
        if response.status == .accepted {
            authState = .authenticated(message.device)
        }

        try? await framedConnection.sendControlEnvelope(.init(replyTo: envelopeID, message: .pairResponse(response)))
    }

    private func replySessionList(replyTo: MessageID) async {
        let message = await runtime.listSessionsMessage(for: authenticatedDeviceID())
        try? await framedConnection.sendControlEnvelope(.init(replyTo: replyTo, message: .sessionList(message)))
    }

    private func sendUnauthorized(replyTo: MessageID?) async {
        let deniedDeviceID: DeviceID?
        switch authState {
        case let .untrusted(device), let .authenticated(device):
            deniedDeviceID = device.id
        case .awaitingHello:
            deniedDeviceID = nil
        }
        await runtime.logDenied(deviceID: deniedDeviceID, note: "Unauthorized control message")
        await sendError(.unauthorized, "Request denied", replyTo: replyTo)
    }

    private func sendError(_ code: ProtocolErrorCode, _ message: String, replyTo: MessageID?) async {
        let errorMessage = ProtocolErrorMessage(code: code, message: message, isRetryable: false)
        try? await framedConnection.sendControlEnvelope(.init(replyTo: replyTo, message: .error(errorMessage)))
    }

    private func handleRateLimitExceeded(kind: String) async {
        logger.error(
            "Closing peer after request flood",
            metadata: [
                "peerID": id.uuidString,
                "kind": kind,
            ]
        )
        await sendError(.rateLimited, "Request denied", replyTo: nil)
        stopSoon()
    }

    private func authenticatedDeviceID() -> DeviceID? {
        guard case let .authenticated(device) = authState else {
            return nil
        }

        return device.id
    }

    func stopIfAuthenticated(deviceID: DeviceID) {
        guard authenticatedDeviceID() == deviceID else {
            return
        }

        stop()
    }

    private func stopSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(APTerminalConfiguration.defaultPeerStopDelayMilliseconds))
            self?.stop()
        }
    }
}
