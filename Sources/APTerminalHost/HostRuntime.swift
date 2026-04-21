import CryptoKit
import Foundation
import APTerminalCore
import APTerminalProtocol
import APTerminalSecurity

public enum HostAuthenticationError: Error, Equatable {
    case deviceMismatch
    case challengeMismatch
    case challengeExpired
    case proofExpired
    case trustedDeviceMissing
    case invalidSignature
}

public enum HostSessionLaunchPolicyError: Error, Equatable {
    case shellPathNotAllowed(String)
    case workingDirectoryNotAllowed(String)
}

public struct HostRuntimeConfiguration: Sendable {
    public var connectionMode: HostConnectionMode
    public var bootstrapEndpointKind: HostEndpointKind
    public var allowExternalTerminalPreviews: Bool
    public var allowManagedSessionContentPreviews: Bool
    public var pairingTokenLifetimeSeconds: TimeInterval
    public var singleUseBootstrapPayloads: Bool
    public var secureSessionOfferLifetimeSeconds: TimeInterval
    public var authenticationChallengeLifetimeSeconds: TimeInterval
    public var authenticationProofFreshnessWindowSeconds: TimeInterval
    public var sessionLaunchProfiles: [HostSettings.SessionLaunchProfile]
    public var allowedWorkingDirectories: [String]

    public init(
        connectionMode: HostConnectionMode = .lan,
        bootstrapEndpointKind: HostEndpointKind = .localNetwork,
        allowExternalTerminalPreviews: Bool = true,
        allowManagedSessionContentPreviews: Bool = true,
        pairingTokenLifetimeSeconds: TimeInterval = APTerminalConfiguration.defaultPairingTokenLifetime,
        singleUseBootstrapPayloads: Bool = true,
        secureSessionOfferLifetimeSeconds: TimeInterval = APTerminalConfiguration.defaultSecureSessionOfferLifetime,
        authenticationChallengeLifetimeSeconds: TimeInterval = APTerminalConfiguration.defaultAuthenticationChallengeLifetime,
        authenticationProofFreshnessWindowSeconds: TimeInterval = APTerminalConfiguration.defaultAuthenticationProofFreshnessWindow,
        sessionLaunchProfiles: [HostSettings.SessionLaunchProfile] = [],
        allowedWorkingDirectories: [String] = []
    ) {
        self.connectionMode = connectionMode
        self.bootstrapEndpointKind = bootstrapEndpointKind
        self.allowExternalTerminalPreviews = allowExternalTerminalPreviews
        self.allowManagedSessionContentPreviews = allowManagedSessionContentPreviews
        self.pairingTokenLifetimeSeconds = pairingTokenLifetimeSeconds
        self.singleUseBootstrapPayloads = singleUseBootstrapPayloads
        self.secureSessionOfferLifetimeSeconds = secureSessionOfferLifetimeSeconds
        self.authenticationChallengeLifetimeSeconds = authenticationChallengeLifetimeSeconds
        self.authenticationProofFreshnessWindowSeconds = authenticationProofFreshnessWindowSeconds
        self.sessionLaunchProfiles = sessionLaunchProfiles
        self.allowedWorkingDirectories = allowedWorkingDirectories
    }
}

public actor HostRuntime {
    nonisolated public let hostIdentity: DeviceIdentity
    nonisolated public let hostSigningPublicKey: Data
    nonisolated public let connectionMode: HostConnectionMode
    nonisolated public let bootstrapEndpointKind: HostEndpointKind
    nonisolated public let secureSessionOfferLifetimeSeconds: TimeInterval

    private let sessionManager: SessionManager
    private let trustRegistry: TrustedDeviceRegistry
    private let pairingService: PairingService
    private let auditLogger: AuditLogger
    private let signingPrivateKey: Curve25519.Signing.PrivateKey
    private var externalSessionProvider: ExternalSessionProviding?
    private var configuration: HostRuntimeConfiguration

    public init(
        hostIdentity: DeviceIdentity,
        sessionManager: SessionManager,
        trustRegistry: TrustedDeviceRegistry,
        pairingService: PairingService,
        auditLogger: AuditLogger,
        signingPrivateKey: Curve25519.Signing.PrivateKey,
        externalSessionProvider: ExternalSessionProviding? = nil,
        configuration: HostRuntimeConfiguration = .init()
    ) {
        self.hostIdentity = hostIdentity
        self.hostSigningPublicKey = signingPrivateKey.publicKey.rawRepresentation
        self.connectionMode = configuration.connectionMode
        self.bootstrapEndpointKind = configuration.bootstrapEndpointKind
        self.secureSessionOfferLifetimeSeconds = configuration.secureSessionOfferLifetimeSeconds
        self.sessionManager = sessionManager
        self.trustRegistry = trustRegistry
        self.pairingService = pairingService
        self.auditLogger = auditLogger
        self.signingPrivateKey = signingPrivateKey
        self.externalSessionProvider = externalSessionProvider
        self.configuration = configuration
    }

    public func createPairingToken(lifetime: TimeInterval? = nil) async -> PairingToken {
        let resolvedLifetime = lifetime ?? configuration.pairingTokenLifetimeSeconds
        return await pairingService.createToken(
            lifetime: resolvedLifetime,
            invalidatingExisting: configuration.singleUseBootstrapPayloads
        )
    }

    public func hostSigningPrivateKeySignature(for payload: Data) throws -> Data {
        try signingPrivateKey.signature(for: payload)
    }

    public func trustedDevices() async -> [TrustedDeviceRecord] {
        await trustRegistry.allDevices()
    }

    public func logDenied(deviceID: DeviceID?, note: String? = nil) async {
        try? await auditLogger.log(.init(kind: .connectionDenied, deviceID: deviceID, note: note))
    }

    public func revoke(deviceID: DeviceID) async throws {
        try await trustRegistry.revoke(deviceID: deviceID)
        try await auditLogger.log(.init(kind: .deviceRevoked, deviceID: deviceID))
    }

    public func trustedDeviceRecord(for deviceID: DeviceID) async -> TrustedDeviceRecord? {
        await trustRegistry.record(for: deviceID)
    }

    @discardableResult
    public func setPreviewAccessModes(
        _ previewAccessModes: Set<HostConnectionMode>,
        for deviceID: DeviceID
    ) async throws -> TrustedDeviceRecord? {
        let previousModes = await trustRegistry.record(for: deviceID)?.previewAccessModes ?? []
        guard let updatedRecord = try await trustRegistry.setPreviewAccessModes(previewAccessModes, for: deviceID) else {
            return nil
        }

        for mode in HostConnectionMode.allCases where previousModes.contains(mode) == false && previewAccessModes.contains(mode) {
            try await auditLogger.log(
                .init(
                    kind: .previewAccessGranted,
                    deviceID: deviceID,
                    note: "mode=\(mode.rawValue)"
                )
            )
        }

        for mode in HostConnectionMode.allCases where previousModes.contains(mode) && previewAccessModes.contains(mode) == false {
            try await auditLogger.log(
                .init(
                    kind: .previewAccessRevoked,
                    deviceID: deviceID,
                    note: "mode=\(mode.rawValue)"
                )
            )
        }

        return updatedRecord
    }

    public func previewAccessModes(for deviceID: DeviceID) async -> [HostConnectionMode] {
        guard let record = await trustRegistry.record(for: deviceID) else {
            return []
        }

        return HostConnectionMode.allCases.filter { record.previewAccessModes.contains($0) }
    }

    public func updatePreviewConfiguration(
        allowExternalTerminalPreviews: Bool,
        allowManagedSessionContentPreviews: Bool,
        externalSessionProvider: ExternalSessionProviding?
    ) async {
        let providerChanged: Bool
        switch (self.externalSessionProvider, externalSessionProvider) {
        case (nil, nil):
            providerChanged = false
        case let (lhs?, rhs?):
            providerChanged = lhs !== rhs
        default:
            providerChanged = true
        }

        if providerChanged {
            await self.externalSessionProvider?.invalidate()
            self.externalSessionProvider = externalSessionProvider
        }

        configuration.allowExternalTerminalPreviews = allowExternalTerminalPreviews
        configuration.allowManagedSessionContentPreviews = allowManagedSessionContentPreviews
    }

    public func logSecureSessionFailure(deviceID: DeviceID?, note: String) async {
        try? await auditLogger.log(.init(kind: .connectionDenied, deviceID: deviceID, note: note))
    }

    public func makeAuthChallenge() async -> AuthChallengeMessage {
        let issuedAt = Date()
        let expiresAt = issuedAt.addingTimeInterval(configuration.authenticationChallengeLifetimeSeconds)
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        return AuthChallengeMessage(nonce: nonce, issuedAt: issuedAt, expiresAt: expiresAt)
    }

    public func authenticate(
        _ proof: AuthProofMessage,
        challenge: AuthChallengeMessage,
        expectedDeviceID: DeviceID
    ) async -> Result<Void, HostAuthenticationError> {
        do {
            guard proof.deviceID == expectedDeviceID else {
                throw HostAuthenticationError.deviceMismatch
            }

            guard
                proof.challengeNonce == challenge.nonce,
                abs(proof.challengeIssuedAt.timeIntervalSince(challenge.issuedAt)) <= 1
            else {
                throw HostAuthenticationError.challengeMismatch
            }

            let now = Date()
            guard challenge.expiresAt > now else {
                throw HostAuthenticationError.challengeExpired
            }

            guard abs(proof.signedAt.timeIntervalSince(now)) <= configuration.authenticationProofFreshnessWindowSeconds else {
                throw HostAuthenticationError.proofExpired
            }

            guard let trustedRecord = await trustRegistry.record(for: proof.deviceID) else {
                throw HostAuthenticationError.trustedDeviceMissing
            }

            let trustedKey = try trustedRecord.publicKey()
            let payload = AuthProofMessage.signingPayload(
                challengeNonce: proof.challengeNonce,
                challengeIssuedAt: proof.challengeIssuedAt,
                deviceID: proof.deviceID,
                protocolVersion: proof.protocolVersion,
                signedAt: proof.signedAt
            )

            guard trustedKey.isValidSignature(proof.signature, for: payload) else {
                throw HostAuthenticationError.invalidSignature
            }

            try await trustRegistry.markSeen(deviceID: proof.deviceID)
            try await auditLogger.log(.init(kind: .authProofAccepted, deviceID: proof.deviceID))
            try await auditLogger.log(.init(kind: .connectionAccepted, deviceID: proof.deviceID))
            return .success(())
        } catch let error as HostAuthenticationError {
            try? await auditLogger.log(.init(kind: .authProofRejected, deviceID: proof.deviceID, note: String(describing: error)))
            return .failure(error)
        } catch {
            try? await auditLogger.log(.init(kind: .authProofRejected, deviceID: proof.deviceID, note: "Unexpected authentication failure"))
            return .failure(.invalidSignature)
        }
    }

    public func logAuthChallengeIssued(deviceID: DeviceID) async {
        try? await auditLogger.log(.init(kind: .authChallengeIssued, deviceID: deviceID))
    }

    public func pair(_ request: PairRequestMessage) async -> PairResponseMessage {
        do {
            try await pairingService.validate(request)
            _ = try await trustRegistry.trust(identity: request.device, publicKeyData: request.publicKey)
            try await auditLogger.log(.init(kind: .devicePaired, deviceID: request.device.id))
            try await auditLogger.log(.init(kind: .connectionAccepted, deviceID: request.device.id))

            return PairResponseMessage(
                status: .accepted,
                assignedDeviceID: request.device.id,
                rejectionReason: nil,
                hostPublicKey: hostSigningPublicKey
            )
        } catch PairingValidationError.tokenExpired {
            try? await auditLogger.log(.init(kind: .connectionDenied, deviceID: request.device.id, note: "Pairing token expired"))
            return PairResponseMessage(
                status: .expired,
                assignedDeviceID: nil,
                rejectionReason: "Pairing token expired",
                hostPublicKey: hostSigningPublicKey
            )
        } catch {
            try? await auditLogger.log(.init(kind: .connectionDenied, deviceID: request.device.id, note: "Pairing rejected"))
            return PairResponseMessage(
                status: .rejected,
                assignedDeviceID: nil,
                rejectionReason: "Pairing request rejected",
                hostPublicKey: hostSigningPublicKey
            )
        }
    }

    public func listSessionsMessage(for deviceID: DeviceID? = nil) async -> SessionListMessage {
        let includePreviewContent = await deviceCanAccessPreviewContent(deviceID)
        let managedSessions = await sessionManager.listSessions().map {
            sanitizedManagedSessionSummary($0, includePreviewContent: includePreviewContent)
        }
        let externalSessions = configuration.allowExternalTerminalPreviews && includePreviewContent
            ? (await externalSessionProvider?.listSessions() ?? [])
            : []
        let sessions = (managedSessions + externalSessions)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }

        if includePreviewContent, sessions.contains(where: { $0.previewExcerpt.isEmpty == false || $0.isReadOnlyPreview }) {
            try? await auditLogger.log(
                .init(
                    kind: .previewAccessUsed,
                    deviceID: deviceID,
                    note: "Preview content listed"
                )
            )
        }

        return SessionListMessage(sessions: sessions)
    }

    public func createSession(
        _ request: CreateSessionRequest,
        requestedBy deviceID: DeviceID? = nil
    ) async throws -> SessionListMessage {
        let launchPolicy = try resolveLaunchRequest(request)
        _ = try await sessionManager.createSession(
            shellPath: launchPolicy.shellPath,
            workingDirectory: launchPolicy.workingDirectory,
            initialSize: request.initialSize
        )
        try? await auditLogger.log(
            .init(
                kind: .remoteSessionCreated,
                deviceID: deviceID,
                note: "profile=\(launchPolicy.profileName)"
            )
        )
        return await listSessionsMessage(for: deviceID)
    }

    public func renameSession(
        _ request: RenameSessionRequest,
        requestedBy deviceID: DeviceID? = nil
    ) async throws -> SessionListMessage {
        try await ensureManagedSessionOperationSupported(for: request.sessionID)
        _ = try await sessionManager.renameSession(id: request.sessionID, title: request.title)
        return await listSessionsMessage(for: deviceID)
    }

    public func closeSession(
        _ request: CloseSessionRequest,
        requestedBy deviceID: DeviceID? = nil
    ) async throws -> SessionListMessage {
        try await ensureManagedSessionOperationSupported(for: request.sessionID)
        try await sessionManager.closeSession(id: request.sessionID)
        return await listSessionsMessage(for: deviceID)
    }

    public func closeManagedSessionLocally(sessionID: SessionID) async throws {
        try await ensureManagedSessionOperationSupported(for: sessionID)
        try await sessionManager.closeSession(id: sessionID)
    }

    public func resizeSession(
        _ request: ResizeSessionRequest,
        requestedBy deviceID: DeviceID? = nil
    ) async throws -> SessionListMessage {
        try await ensureManagedSessionOperationSupported(for: request.sessionID)
        try await sessionManager.resizeSession(id: request.sessionID, size: request.size)
        return await listSessionsMessage(for: deviceID)
    }

    public func attach(
        sessionID: SessionID,
        consumerID: UUID,
        requestedBy deviceID: DeviceID? = nil,
        onChunk: @escaping @Sendable (TerminalStreamChunk) -> Void
    ) async throws {
        do {
            try await sessionManager.attach(sessionID: sessionID, consumerID: consumerID, onChunk: onChunk)
        } catch SessionManagerError.sessionNotFound {
            guard configuration.allowExternalTerminalPreviews else {
                throw SessionManagerError.sessionNotFound(sessionID)
            }
            guard let externalSessionProvider, await externalSessionProvider.handles(sessionID: sessionID) else {
                throw SessionManagerError.sessionNotFound(sessionID)
            }
            guard await deviceCanAccessPreviewContent(deviceID) else {
                try? await auditLogger.log(
                    .init(
                        kind: .previewAccessDenied,
                        deviceID: deviceID,
                        sessionID: sessionID,
                        note: "Preview attach denied"
                    )
                )
                throw ExternalTerminalSessionProviderError.previewAccessDenied(sessionID)
            }
            try await externalSessionProvider.attach(sessionID: sessionID, consumerID: consumerID, onChunk: onChunk)
            try await auditLogger.log(.init(kind: .externalPreviewAttached, sessionID: sessionID))
            try await auditLogger.log(
                .init(
                    kind: .previewAccessUsed,
                    deviceID: deviceID,
                    sessionID: sessionID,
                    note: "External preview attached"
                )
            )
        }
        try await auditLogger.log(.init(kind: .sessionAttached, sessionID: sessionID))
    }

    public func detach(sessionID: SessionID, consumerID: UUID) async {
        await sessionManager.detach(sessionID: sessionID, consumerID: consumerID)
        await externalSessionProvider?.detach(sessionID: sessionID, consumerID: consumerID)
        try? await auditLogger.log(.init(kind: .sessionDetached, sessionID: sessionID))
    }

    public func lockSession(_ request: LockSessionRequest) async {
        await sessionManager.lockSession(sessionID: request.sessionID)
        await externalSessionProvider?.lockSession(request.sessionID)
    }

    public func sendInput(_ chunk: TerminalStreamChunk) async throws {
        try await ensureManagedSessionOperationSupported(for: chunk.sessionID)
        try await sessionManager.sendInput(sessionID: chunk.sessionID, data: chunk.data)
    }

    private func ensureManagedSessionOperationSupported(for sessionID: SessionID) async throws {
        guard let externalSessionProvider, await externalSessionProvider.handles(sessionID: sessionID) else {
            return
        }

        guard configuration.allowExternalTerminalPreviews else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }

        guard await externalSessionProvider.sessionExists(sessionID) else {
            throw ExternalTerminalSessionProviderError.sessionNotFound(sessionID)
        }

        throw ExternalTerminalSessionProviderError.unsupportedOperation(sessionID)
    }

    private func deviceCanAccessPreviewContent(_ deviceID: DeviceID?) async -> Bool {
        guard let deviceID else {
            return false
        }

        guard let record = await trustRegistry.record(for: deviceID) else {
            return false
        }

        return record.allowsPreviewAccess(in: configuration.connectionMode)
    }

    private func sanitizedManagedSessionSummary(
        _ summary: SessionSummary,
        includePreviewContent: Bool
    ) -> SessionSummary {
        guard configuration.allowManagedSessionContentPreviews, includePreviewContent else {
            return SessionSummary(
                id: summary.id,
                title: summary.title,
                shellPath: summary.shellPath,
                workingDirectory: summary.workingDirectory,
                state: summary.state,
                source: summary.source,
                capabilities: summary.capabilities,
                pid: summary.pid,
                size: summary.size,
                createdAt: summary.createdAt,
                lastActivityAt: summary.lastActivityAt,
                previewExcerpt: ""
            )
        }

        return summary
    }

    private func resolveLaunchRequest(
        _ request: CreateSessionRequest
    ) throws -> (profileName: String, shellPath: String, workingDirectory: String) {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let matchedProfile = configuration.sessionLaunchProfiles.first { profile in
            guard let requestedShellPath = request.shellPath else {
                return false
            }

            return profile.shellPath == requestedShellPath
        }

        if let requestedShellPath = request.shellPath,
           requestedShellPath != loginShell,
           matchedProfile == nil {
            throw HostSessionLaunchPolicyError.shellPathNotAllowed(requestedShellPath)
        }

        let selectedProfileName = matchedProfile?.displayName ?? "Login Shell"
        let selectedShellPath = matchedProfile?.shellPath ?? loginShell
        let selectedWorkingDirectory = try resolveWorkingDirectory(
            request.workingDirectory ?? matchedProfile?.defaultWorkingDirectory,
            homeDirectory: homeDirectory
        )

        return (
            profileName: selectedProfileName,
            shellPath: selectedShellPath,
            workingDirectory: selectedWorkingDirectory
        )
    }

    private func resolveWorkingDirectory(
        _ requestedWorkingDirectory: String?,
        homeDirectory: String
    ) throws -> String {
        let candidate = requestedWorkingDirectory ?? homeDirectory
        let standardizedCandidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let standardizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path

        if standardizedCandidate == standardizedHome {
            return standardizedCandidate
        }

        let allowedRoots = configuration.allowedWorkingDirectories.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        guard allowedRoots.contains(where: { standardizedCandidate == $0 || standardizedCandidate.hasPrefix($0 + "/") }) else {
            throw HostSessionLaunchPolicyError.workingDirectoryNotAllowed(standardizedCandidate)
        }

        return standardizedCandidate
    }
}
