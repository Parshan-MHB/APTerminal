import CryptoKit
import Foundation
import Network
import XCTest
@testable import APTerminalClient
@testable import APTerminalCore
@testable import APTerminalHost
@testable import APTerminalProtocol
@testable import APTerminalProtocolCodec
@testable import APTerminalSecurity
@testable import APTerminalTransport

final class HostClientIntegrationTests: XCTestCase {
    func testSecureSessionReadyCarriesProtectedHostMetadata() async throws {
        let runtime = makeRuntime(configuration: .init(connectionMode: .internetVPN, bootstrapEndpointKind: .overlayVPN))
        let server = try HostServer(runtime: runtime, port: 0, advertiseBonjour: false)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }

        let device = DeviceIdentity(id: .random(), name: "Metadata iPhone", platform: .iOS, appVersion: "0.1.0")
        let signingKey = Curve25519.Signing.PrivateKey()
        let (hello, ready) = try await peer.connectAndEstablishSecureSession(
            device: device,
            signingPrivateKey: signingKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )

        XCTAssertEqual(hello.device.id, runtime.hostIdentity.id)
        XCTAssertEqual(hello.device.name, "")
        XCTAssertNil(hello.connectionMode)
        XCTAssertNil(hello.endpointKind)
        XCTAssertNil(hello.previewAccessModes)

        XCTAssertEqual(ready.hostIdentity, runtime.hostIdentity)
        XCTAssertEqual(ready.connectionMode, .internetVPN)
        XCTAssertEqual(ready.endpointKind, .overlayVPN)
        XCTAssertEqual(ready.previewAccessModes ?? [], [])
    }

    func testUnpairedClientCannotEnumerateSessions() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Unauthorized iPhone")

        _ = try await client.manager.connect(host: "127.0.0.1", port: port)

        do {
            _ = try await client.manager.listSessions()
            XCTFail("Expected unauthorized session listing to fail")
        } catch let error as ClientConnectionError {
            guard case let .protocolError(protocolError) = error else {
                XCTFail("Expected protocol error, got \(error)")
                return
            }
            XCTAssertEqual(protocolError.code, .unauthorized)
        }
    }

    func testRevokedDeviceCannotReconnect() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Revoked iPhone")

        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await client.manager.listSessions()

        try await runtime.revoke(deviceID: client.deviceIdentity.id)
        await client.manager.disconnect()

        do {
            _ = try await client.manager.connect(host: "127.0.0.1", port: port)
            XCTFail("Expected revoked device to be denied")
        } catch let error as ClientConnectionError {
            guard case let .protocolError(protocolError) = error else {
                XCTFail("Expected protocol error, got \(error)")
                return
            }
            XCTAssertEqual(protocolError.code, .unauthorized)
        }
    }

    func testClientReconnectRestoresAttachedSessionAfterServerRestart() async throws {
        let runtime = try makeRuntime()
        let initialServer = try HostServer(runtime: runtime, port: 0)
        initialServer.start()

        let port = try await waitForPort(on: initialServer)
        let client = makeClient(name: "Reconnect iPhone")

        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)

        let createdSessions = try await client.manager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            size: .init(rows: 24, columns: 80)
        )
        let sessionID = try XCTUnwrap(createdSessions.first?.id)
        _ = try await client.manager.attachSession(id: sessionID)

        initialServer.stop()
        try await Task.sleep(nanoseconds: 500_000_000)

        let restartedServer = try HostServer(runtime: runtime, port: port)
        restartedServer.start()
        defer { restartedServer.stop() }
        _ = try await waitForPort(on: restartedServer)

        _ = try await client.manager.reconnect()
        let sessions = try await client.manager.listSessions()

        XCTAssertTrue(sessions.contains(where: { $0.id == sessionID }))
    }

    func testTrustedReconnectRejectsAuthenticationProofSignedByWrongKey() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Wrong Key iPhone")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let rawPeer = RawProtocolPeer(port: port)
        defer { rawPeer.disconnect() }

        _ = try await rawPeer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authResult = try await rawPeer.authenticate(
            with: Curve25519.Signing.PrivateKey(),
            deviceID: client.deviceIdentity.id
        )

        XCTAssertTrue([AuthenticationStatus.rejected, .replayed].contains(authResult.status))
    }

    func testTrustedReconnectRejectsStaleAuthenticationProof() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Stale Proof iPhone")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let rawPeer = RawProtocolPeer(port: port)
        defer { rawPeer.disconnect() }

        _ = try await rawPeer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authResult = try await rawPeer.authenticate(
            with: client.privateKey,
            deviceID: client.deviceIdentity.id,
            signedAt: Date(timeIntervalSinceNow: -120)
        )

        XCTAssertTrue([AuthenticationStatus.stale, .replayed].contains(authResult.status))
    }

    func testTrustedReconnectRejectsReplayedAuthenticationProof() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Replay iPhone")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let rawPeer = RawProtocolPeer(port: port)
        defer { rawPeer.disconnect() }

        _ = try await rawPeer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let challenge = try await rawPeer.requestAuthChallenge()
        let proof = try rawPeer.makeAuthProof(
            privateKey: client.privateKey,
            challenge: challenge,
            deviceID: client.deviceIdentity.id
        )
        let firstReply = try await rawPeer.sendAuthProof(proof)
        XCTAssertEqual(firstReply.status, .accepted)

        let replayReply = try await rawPeer.sendAuthProof(proof)
        XCTAssertEqual(replayReply.status, .replayed)
    }

    func testTrustedReconnectRejectsAuthenticationProofWithMismatchedDeviceID() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Mismatched Device ID")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let rawPeer = RawProtocolPeer(port: port)
        defer { rawPeer.disconnect() }

        _ = try await rawPeer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authResult = try await rawPeer.authenticate(
            with: client.privateKey,
            deviceID: .random()
        )

        XCTAssertTrue([AuthenticationStatus.rejected, .replayed].contains(authResult.status))
    }

    func testPairingRejectsKeyThatDoesNotMatchSecureSessionIdentity() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Pairing Key Mismatch")
        let token = await runtime.createPairingToken(lifetime: 60)

        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }
        _ = try await peer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )

        let mismatchedKey = Curve25519.Signing.PrivateKey()
        let pairResponse = try await peer.sendPairRequest(
            token: token,
            device: client.deviceIdentity,
            signingPrivateKey: mismatchedKey
        )

        XCTAssertEqual(pairResponse.status, .rejected)
    }

    func testSecureSessionRejectsWrongPinnedHostIdentity() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Wrong Host Pin")

        do {
            _ = try await client.manager.connect(
                host: "127.0.0.1",
                port: port,
                expectedHostPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            )
            XCTFail("Expected secure session establishment to reject the wrong host key")
        } catch let error as ClientConnectionError {
            XCTAssertEqual(error, .hostIdentityMismatch)
        }
    }

    func testCorruptedEncryptedFrameDisconnectsPeer() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Corrupted Ciphertext")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }
        _ = try await peer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authReply = try await peer.authenticate(
            with: client.privateKey,
            deviceID: client.deviceIdentity.id
        )
        XCTAssertEqual(authReply.status, .accepted)

        var frame = try peer.makeControlWireFrame(.listSessions(.init()))
        frame[frame.count - 1] ^= 0xFF
        try await peer.sendRawFrame(frame)

        let disconnected = await peer.waitForDisconnect()
        XCTAssertTrue(disconnected)
    }

    func testReplayedEncryptedFrameDisconnectsPeer() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Replayed Secure Frame")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }
        _ = try await peer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authReply = try await peer.authenticate(
            with: client.privateKey,
            deviceID: client.deviceIdentity.id
        )
        XCTAssertEqual(authReply.status, .accepted)

        let frame = try peer.makeControlWireFrame(.listSessions(.init()))
        try await peer.sendRawFrame(frame)
        let firstReply = try await peer.nextEnvelope()
        guard case .sessionList = firstReply.message else {
            XCTFail("Expected a session list reply before replay")
            return
        }

        try await peer.sendRawFrame(frame)
        let disconnected = await peer.waitForDisconnect()
        XCTAssertTrue(disconnected)
    }

    func testSecureSessionFailureWritesAuditEvent() async throws {
        let auditStore = InMemoryAuditEventStore()
        let runtime = makeRuntime(auditStore: auditStore)
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }

        let device = DeviceIdentity(id: .random(), name: "Invalid Secure Session", platform: .iOS, appVersion: "0.1.0")
        let signingKey = Curve25519.Signing.PrivateKey()
        try await peer.sendControl(
            .hello(
                HelloMessage(
                    role: .iosClient,
                    device: device,
                    supportedVersions: [.current],
                    signingPublicKey: signingKey.publicKey.rawRepresentation
                )
            )
        )

        let helloEnvelope = try await peer.nextEnvelope()
        guard case let .hello(hello) = helloEnvelope.message,
              hello.secureSessionOffer != nil
        else {
            XCTFail("Expected hello reply with secure session offer")
            return
        }

        let invalidAccept = SecureSessionAcceptMessage(
            ephemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            signedAt: Date(),
            signature: Data(repeating: 0xAA, count: 64)
        )
        try await peer.sendControl(.secureSessionAccept(invalidAccept))

        let replyEnvelope = try await peer.nextEnvelope()
        guard case let .error(error) = replyEnvelope.message else {
            XCTFail("Expected unauthorized error after invalid secure session proof")
            return
        }
        XCTAssertEqual(error.code, .unauthorized)

        let auditEvents = try await AuditLogger(store: auditStore).recentEvents(limit: 10)
        XCTAssertTrue(auditEvents.contains(where: {
            $0.kind == .connectionDenied &&
                $0.deviceID == device.id &&
                $0.note?.contains("Secure session proof rejected") == true
        }))
    }

    func testHostServerCanDisableBonjourAdvertisement() async throws {
        let runtime = makeRuntime(configuration: .init(connectionMode: .internetVPN))
        let server = try HostServer(runtime: runtime, port: 0, advertiseBonjour: false)
        server.start()
        defer { server.stop() }

        _ = try await waitForPort(on: server)
        XCTAssertFalse(server.isAdvertisingBonjour)
    }

    func testRemoteCreateSessionRejectsUnauthorizedShellPath() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Shell Policy iPhone")

        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)

        do {
            _ = try await client.manager.createSession(
                shellPath: "/usr/bin/python3",
                workingDirectory: nil,
                size: .init(rows: 24, columns: 80)
            )
            XCTFail("Expected disallowed shell path to be rejected")
        } catch let error as ClientConnectionError {
            guard case let .protocolError(protocolError) = error else {
                XCTFail("Expected protocol error, got \(error)")
                return
            }
            XCTAssertEqual(protocolError.code, .forbidden)
        }
    }

    func testOversizedFrameDisconnectsPeer() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(
            runtime: runtime,
            port: 0,
            connectionConfiguration: .init(
                maximumInboundFrameBytes: 32,
                maximumBufferedInboundBytes: 64
            )
        )
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }

        try await peer.sendRawFrame(FrameCodec.encodeFrame(kind: .control, payload: Data(repeating: 0x61, count: 80)))
        let disconnected = await peer.waitForDisconnect()
        XCTAssertTrue(disconnected)
    }

    func testMalformedFramesDisconnectPeer() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }

        for _ in 0..<3 {
            try await peer.sendRawFrame(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        }

        let disconnected = await peer.waitForDisconnect()
        XCTAssertTrue(disconnected)
    }

    func testFloodingControlMessagesTriggersRateLimit() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Flood iPhone")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        await client.manager.disconnect()

        let peer = RawProtocolPeer(port: port)
        defer { peer.disconnect() }

        _ = try await peer.connectAndHello(
            device: client.deviceIdentity,
            signingPrivateKey: client.privateKey,
            expectedHostPublicKey: runtime.hostSigningPublicKey
        )
        let authReply = try await peer.authenticate(
            with: client.privateKey,
            deviceID: client.deviceIdentity.id
        )
        XCTAssertEqual(authReply.status, .accepted)

        for _ in 0..<40 {
            try await peer.sendControl(.listSessions(.init()))
        }

        var receivedRateLimit: ProtocolErrorMessage?
        for _ in 0..<50 {
            let envelope = try await peer.nextEnvelope()
            if case let .error(error) = envelope.message, error.code == .rateLimited {
                receivedRateLimit = error
                break
            }
        }

        XCTAssertEqual(receivedRateLimit?.code, .rateLimited)
    }

    func testPairedDeviceWithoutPreviewPrivilegeCannotAccessExternalPreviewContent() async throws {
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let auditStore = InMemoryAuditEventStore()
        let previewSession = makeExternalPreviewSession(id: "external:terminal:7", preview: "secret preview")
        let provider = StubExternalSessionProvider(sessions: [previewSession])
        let runtime = makeRuntime(
            trustRegistry: trustRegistry,
            auditStore: auditStore,
            externalSessionProvider: provider,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: true,
                allowManagedSessionContentPreviews: true
            )
        )
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "No Preview Privilege")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)

        let sessions = try await client.manager.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == previewSession.id }))

        do {
            _ = try await client.manager.attachSession(id: previewSession.id)
            XCTFail("Expected preview attach to be forbidden without preview privilege")
        } catch let error as ClientConnectionError {
            guard case let .protocolError(protocolError) = error else {
                XCTFail("Expected protocol error, got \(error)")
                return
            }
            XCTAssertEqual(protocolError.code, .forbidden)
        }

        let auditEvents = try await AuditLogger(store: auditStore).recentEvents(limit: 20)
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessDenied && $0.sessionID == previewSession.id }))
    }

    func testPreviewAuthorizedDeviceCanListAndAttachExternalPreviews() async throws {
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let auditStore = InMemoryAuditEventStore()
        let previewSession = makeExternalPreviewSession(id: "external:terminal:9", preview: "rich external preview")
        let provider = StubExternalSessionProvider(sessions: [previewSession])
        let runtime = makeRuntime(
            trustRegistry: trustRegistry,
            auditStore: auditStore,
            externalSessionProvider: provider,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: true,
                allowManagedSessionContentPreviews: true
            )
        )
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Preview Allowed")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await runtime.setPreviewAccessModes([.lan], for: client.deviceIdentity.id)

        let sessions = try await client.manager.listSessions()
        XCTAssertTrue(sessions.contains(where: { $0.id == previewSession.id }))

        _ = try await client.manager.attachSession(id: previewSession.id)
        let attachedSessionIDs = await provider.attachedSessionIDs()
        XCTAssertTrue(attachedSessionIDs.contains(previewSession.id))

        let auditEvents = try await AuditLogger(store: auditStore).recentEvents(limit: 20)
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessGranted && $0.deviceID == client.deviceIdentity.id }))
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessUsed && $0.sessionID == previewSession.id }))
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .externalPreviewAttached && $0.sessionID == previewSession.id }))
    }

    func testRevokedPreviewCapabilityImmediatelyBlocksExternalPreviewAccess() async throws {
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let auditStore = InMemoryAuditEventStore()
        let previewSession = makeExternalPreviewSession(id: "external:terminal:11", preview: "revoked preview")
        let provider = StubExternalSessionProvider(sessions: [previewSession])
        let runtime = makeRuntime(
            trustRegistry: trustRegistry,
            auditStore: auditStore,
            externalSessionProvider: provider,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: true,
                allowManagedSessionContentPreviews: true
            )
        )
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Preview Revoked")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await runtime.setPreviewAccessModes([.lan], for: client.deviceIdentity.id)
        let authorizedSessions = try await client.manager.listSessions()
        XCTAssertTrue(authorizedSessions.contains(where: { $0.id == previewSession.id }))

        _ = try await runtime.setPreviewAccessModes([], for: client.deviceIdentity.id)
        let sessions = try await client.manager.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == previewSession.id }))

        do {
            _ = try await client.manager.attachSession(id: previewSession.id)
            XCTFail("Expected preview attach to fail after revocation")
        } catch let error as ClientConnectionError {
            guard case let .protocolError(protocolError) = error else {
                XCTFail("Expected protocol error, got \(error)")
                return
            }
            XCTAssertEqual(protocolError.code, .forbidden)
        }

        let auditEvents = try await AuditLogger(store: auditStore).recentEvents(limit: 30)
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessRevoked && $0.deviceID == client.deviceIdentity.id }))
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessDenied && $0.sessionID == previewSession.id }))
    }

    func testInternetModeRequiresExplicitExternalPreviewEnablement() async throws {
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let previewSession = makeExternalPreviewSession(id: "external:terminal:13", preview: "internet preview")
        let provider = StubExternalSessionProvider(sessions: [previewSession])
        let runtime = makeRuntime(
            trustRegistry: trustRegistry,
            externalSessionProvider: provider,
            configuration: .init(
                connectionMode: .internetVPN,
                allowExternalTerminalPreviews: false,
                allowManagedSessionContentPreviews: true
            )
        )
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Internet Preview Gate")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await runtime.setPreviewAccessModes([.internetVPN], for: client.deviceIdentity.id)

        let sessions = try await client.manager.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == previewSession.id }))
    }

    func testUpdatingPreviewConfigurationHidesExternalPreviewsWithoutRestartingServer() async throws {
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let previewSession = makeExternalPreviewSession(id: "external:terminal:15", preview: "live preview")
        let initialProvider = StubExternalSessionProvider(sessions: [previewSession])
        let runtime = makeRuntime(
            trustRegistry: trustRegistry,
            externalSessionProvider: initialProvider,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: true,
                allowManagedSessionContentPreviews: true
            )
        )
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Live Preview Toggle")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await runtime.setPreviewAccessModes([.lan], for: client.deviceIdentity.id)

        let initialSessions = try await client.manager.listSessions()
        XCTAssertTrue(initialSessions.contains(where: { $0.id == previewSession.id }))

        await runtime.updatePreviewConfiguration(
            allowExternalTerminalPreviews: false,
            allowManagedSessionContentPreviews: true,
            externalSessionProvider: nil
        )

        let updatedSessions = try await client.manager.listSessions()
        XCTAssertFalse(updatedSessions.contains(where: { $0.id == previewSession.id }))
    }

    func testDisconnectingSpecificAuthenticatedPeerLeavesListenerRunning() async throws {
        let runtime = try makeRuntime()
        let server = try HostServer(runtime: runtime, port: 0)
        server.start()
        defer { server.stop() }

        let port = try await waitForPort(on: server)
        let client = makeClient(name: "Disconnect Me")
        _ = try await client.manager.connect(host: "127.0.0.1", port: port)
        let token = await runtime.createPairingToken(lifetime: 60)
        let pairResponse = try await client.manager.pair(using: token)
        XCTAssertEqual(pairResponse.status, .accepted)
        _ = try await client.manager.listSessions()

        server.disconnectAuthenticatedDevice(client.deviceIdentity.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        do {
            _ = try await client.manager.listSessions()
            XCTFail("Expected disconnected peer to lose its session")
        } catch {
            XCTAssertNotNil(server.port)
        }

        let secondClient = makeClient(name: "Still Allowed")
        _ = try await secondClient.manager.connect(host: "127.0.0.1", port: port)
        let secondToken = await runtime.createPairingToken(lifetime: 60)
        let secondPairResponse = try await secondClient.manager.pair(using: secondToken)
        XCTAssertEqual(secondPairResponse.status, .accepted)
    }

    func testManagedPreviewContentHiddenWithoutPreviewPrivilege() async throws {
        let sessionManager = SessionManager()
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let auditStore = InMemoryAuditEventStore()
        let deviceIdentity = DeviceIdentity(id: .random(), name: "Preview Reader", platform: .iOS, appVersion: "0.1.0")
        let deviceKey = Curve25519.Signing.PrivateKey()
        _ = try await trustRegistry.trust(identity: deviceIdentity, publicKeyData: deviceKey.publicKey.rawRepresentation)

        let runtime = makeRuntime(
            sessionManager: sessionManager,
            trustRegistry: trustRegistry,
            auditStore: auditStore,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: false,
                allowManagedSessionContentPreviews: true
            )
        )

        let session = try await sessionManager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            initialSize: .init(rows: 24, columns: 80)
        )
        try await sessionManager.sendInput(sessionID: session.id, data: Data("printf 'managed-preview-secret\\n'\n".utf8))
        try await waitForManagedPreview(in: sessionManager, sessionID: session.id, substring: "managed-preview-secret")

        let listed = await runtime.listSessionsMessage(for: deviceIdentity.id).sessions
        XCTAssertEqual(listed.first(where: { $0.id == session.id })?.previewExcerpt, "")
    }

    func testManagedPreviewContentVisibleWithPreviewPrivilege() async throws {
        let sessionManager = SessionManager()
        let trustRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore())
        let auditStore = InMemoryAuditEventStore()
        let deviceIdentity = DeviceIdentity(id: .random(), name: "Preview Reader", platform: .iOS, appVersion: "0.1.0")
        let deviceKey = Curve25519.Signing.PrivateKey()
        _ = try await trustRegistry.trust(identity: deviceIdentity, publicKeyData: deviceKey.publicKey.rawRepresentation)

        let runtime = makeRuntime(
            sessionManager: sessionManager,
            trustRegistry: trustRegistry,
            auditStore: auditStore,
            configuration: .init(
                connectionMode: .lan,
                allowExternalTerminalPreviews: false,
                allowManagedSessionContentPreviews: true
            )
        )
        _ = try await runtime.setPreviewAccessModes([.lan], for: deviceIdentity.id)

        let session = try await sessionManager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            initialSize: .init(rows: 24, columns: 80)
        )
        try await sessionManager.sendInput(sessionID: session.id, data: Data("printf 'managed-preview-secret\\n'\n".utf8))
        try await waitForManagedPreview(in: sessionManager, sessionID: session.id, substring: "managed-preview-secret")

        let listed = await runtime.listSessionsMessage(for: deviceIdentity.id).sessions
        XCTAssertTrue(listed.first(where: { $0.id == session.id })?.previewExcerpt.contains("managed-preview-secret") == true)

        let auditEvents = try await AuditLogger(store: auditStore).recentEvents(limit: 20)
        XCTAssertTrue(auditEvents.contains(where: { $0.kind == .previewAccessUsed && $0.deviceID == deviceIdentity.id }))
    }

    private func makeClient(name: String) -> TestClient {
        let privateKey = Curve25519.Signing.PrivateKey()
        let deviceIdentity = DeviceIdentity(
            id: .random(),
            name: name,
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let manager = ConnectionManager(
            deviceIdentity: deviceIdentity,
            privateKey: privateKey,
            trustedHostRegistry: TrustedHostRegistry(store: InMemoryTrustedHostStore())
        )

        return TestClient(manager: manager, privateKey: privateKey, deviceIdentity: deviceIdentity)
    }

    private func makeRuntime() throws -> HostRuntime {
        makeRuntime(
            sessionManager: SessionManager(),
            trustRegistry: TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore()),
            auditStore: InMemoryAuditEventStore(),
            externalSessionProvider: nil,
            configuration: .init()
        )
    }

    private func makeRuntime(
        sessionManager: SessionManager = SessionManager(),
        trustRegistry: TrustedDeviceRegistry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore()),
        auditStore: InMemoryAuditEventStore = InMemoryAuditEventStore(),
        externalSessionProvider: ExternalSessionProviding? = nil,
        configuration: HostRuntimeConfiguration = .init()
    ) -> HostRuntime {
        HostRuntime(
            hostIdentity: DeviceIdentity(
                id: .random(),
                name: "Test Mac",
                platform: .macOS,
                appVersion: "0.1.0"
            ),
            sessionManager: sessionManager,
            trustRegistry: trustRegistry,
            pairingService: PairingService(),
            auditLogger: AuditLogger(store: auditStore),
            signingPrivateKey: Curve25519.Signing.PrivateKey(),
            externalSessionProvider: externalSessionProvider,
            configuration: configuration
        )
    }

    private func waitForPort(on server: HostServer) async throws -> UInt16 {
        for _ in 0..<50 {
            if let port = server.port?.rawValue {
                return port
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Server did not publish a port in time")
        return 0
    }

    private func makeExternalPreviewSession(id: String, preview: String) -> SessionSummary {
        SessionSummary(
            id: SessionID(rawValue: id),
            title: "Terminal Preview",
            shellPath: "Terminal.app",
            workingDirectory: "/dev/ttys001",
            state: .running,
            source: .terminalApp,
            capabilities: .readOnlyPreview,
            pid: nil,
            size: .init(rows: 40, columns: 120),
            createdAt: Date(),
            lastActivityAt: Date(),
            previewExcerpt: preview
        )
    }

    private func waitForManagedPreview(
        in sessionManager: SessionManager,
        sessionID: SessionID,
        substring: String
    ) async throws {
        for _ in 0..<40 {
            if await sessionManager.sessionSummary(id: sessionID)?.previewExcerpt.contains(substring) == true {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Managed session preview did not contain expected output")
    }
}

private struct TestClient {
    let manager: ConnectionManager
    let privateKey: Curve25519.Signing.PrivateKey
    let deviceIdentity: DeviceIdentity
}

private actor StubExternalSessionProvider: ExternalSessionProviding {
    private let sessionsByID: [SessionID: SessionSummary]
    private var attached: Set<SessionID> = []

    init(sessions: [SessionSummary]) {
        self.sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    func handles(sessionID: SessionID) async -> Bool {
        sessionsByID[sessionID] != nil
    }

    func sessionExists(_ sessionID: SessionID) async -> Bool {
        sessionsByID[sessionID] != nil
    }

    func listSessions() async -> [SessionSummary] {
        sessionsByID.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func attach(
        sessionID: SessionID,
        consumerID: UUID,
        onChunk: @escaping @Sendable (TerminalStreamChunk) -> Void
    ) async throws {
        guard let session = sessionsByID[sessionID] else {
            throw ExternalTerminalSessionProviderError.sessionNotFound(sessionID)
        }

        attached.insert(sessionID)
        onChunk(
            TerminalStreamChunk(
                sessionID: sessionID,
                direction: .output,
                sequenceNumber: 1,
                data: Data(session.previewExcerpt.utf8)
            )
        )
    }

    func detach(sessionID: SessionID, consumerID: UUID) async {
        attached.remove(sessionID)
    }

    func lockSession(_ sessionID: SessionID) async {
        attached.remove(sessionID)
    }

    func invalidate() async {
        attached.removeAll()
    }

    func attachedSessionIDs() -> Set<SessionID> {
        attached
    }
}

private actor EnvelopeBuffer {
    private var buffered: [ControlEnvelope] = []
    private var waiters: [CheckedContinuation<ControlEnvelope, Never>] = []

    func append(_ envelope: ControlEnvelope) {
        if waiters.isEmpty == false {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: envelope)
            return
        }

        buffered.append(envelope)
    }

    func nextEnvelope() async -> ControlEnvelope {
        if buffered.isEmpty == false {
            return buffered.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class RawProtocolPeer: @unchecked Sendable {
    private let connection: NWConnection
    private let framedConnection: FramedConnection
    private let envelopes = EnvelopeBuffer()
    private let disconnectLock = NSLock()
    private var isDisconnected = false

    init(port: UInt16) {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        self.connection = connection
        self.framedConnection = FramedConnection(
            connection: connection,
            label: "com.apterminal.tests.raw-peer.\(UUID().uuidString)"
        )

        framedConnection.onControlEnvelope = { [envelopes] envelope in
            Task {
                await envelopes.append(envelope)
            }
        }
        framedConnection.onDisconnect = { [weak self] in
            self?.disconnectLock.lock()
            self?.isDisconnected = true
            self?.disconnectLock.unlock()
        }
        framedConnection.start()
    }

    func disconnect() {
        framedConnection.cancel()
    }

    func connectAndHello(
        device: DeviceIdentity,
        signingPrivateKey: Curve25519.Signing.PrivateKey,
        expectedHostPublicKey: Data? = nil
    ) async throws -> HelloMessage {
        let (hello, _) = try await connectAndEstablishSecureSession(
            device: device,
            signingPrivateKey: signingPrivateKey,
            expectedHostPublicKey: expectedHostPublicKey
        )
        return hello
    }

    func connectAndEstablishSecureSession(
        device: DeviceIdentity,
        signingPrivateKey: Curve25519.Signing.PrivateKey,
        expectedHostPublicKey: Data? = nil
    ) async throws -> (hello: HelloMessage, ready: SecureSessionReadyMessage) {
        try await sendControl(
            .hello(
                HelloMessage(
                    role: .iosClient,
                    device: device,
                    supportedVersions: [.current],
                    signingPublicKey: signingPrivateKey.publicKey.rawRepresentation
                )
            )
        )

        let envelope = try await nextEnvelope()
        guard case let .hello(hello) = envelope.message else {
            throw NSError(domain: "RawProtocolPeer", code: 1)
        }

        guard let hostPublicKey = hello.signingPublicKey,
              let offer = hello.secureSessionOffer
        else {
            throw NSError(domain: "RawProtocolPeer", code: 4)
        }

        if let expectedHostPublicKey, expectedHostPublicKey != hostPublicKey {
            throw ClientConnectionError.hostIdentityMismatch
        }

        let offerPayload = SecureSessionOfferMessage.signingPayload(
            clientDeviceID: device.id,
            clientSigningPublicKey: signingPrivateKey.publicKey.rawRepresentation,
            hostDeviceID: hello.device.id,
            hostEphemeralPublicKey: offer.ephemeralPublicKey,
            issuedAt: offer.issuedAt,
            expiresAt: offer.expiresAt,
            protocolVersion: .current
        )
        let hostSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: hostPublicKey)
        guard hostSigningKey.isValidSignature(offer.signature, for: offerPayload) else {
            throw NSError(domain: "RawProtocolPeer", code: 5)
        }

        let clientEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientEphemeralPublicKey = clientEphemeralPrivateKey.publicKey.rawRepresentation
        let signedAt = Date()
        let acceptPayload = SecureSessionAcceptMessage.signingPayload(
            clientDeviceID: device.id,
            clientSigningPublicKey: signingPrivateKey.publicKey.rawRepresentation,
            hostDeviceID: hello.device.id,
            hostEphemeralPublicKey: offer.ephemeralPublicKey,
            hostOfferIssuedAt: offer.issuedAt,
            hostOfferExpiresAt: offer.expiresAt,
            clientEphemeralPublicKey: clientEphemeralPublicKey,
            signedAt: signedAt,
            protocolVersion: .current
        )
        let signature = try signingPrivateKey.signature(for: acceptPayload)
        try await sendControl(
            .secureSessionAccept(
                .init(
                    ephemeralPublicKey: clientEphemeralPublicKey,
                    signedAt: signedAt,
                    signature: signature
                )
            )
        )

        let hostEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: offer.ephemeralPublicKey)
        let sharedSecret = try clientEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: hostEphemeralKey)
        let transcript = acceptPayload + offer.signature
        let sessionKeys = SecureSessionKeyDerivation.deriveKeys(
            sharedSecret: sharedSecret,
            transcript: transcript,
            role: .client
        )
        framedConnection.activateSecureSession(keys: sessionKeys)

        let readyEnvelope = try await nextEnvelope()
        guard case let .secureSessionReady(readyMessage) = readyEnvelope.message else {
            throw NSError(domain: "RawProtocolPeer", code: 6)
        }

        return (hello, readyMessage)
    }

    func authenticate(
        with privateKey: Curve25519.Signing.PrivateKey,
        deviceID: DeviceID,
        signedAt: Date = Date()
    ) async throws -> AuthResultMessage {
        let challenge = try await requestAuthChallenge()
        let proof = try makeAuthProof(
            privateKey: privateKey,
            challenge: challenge,
            deviceID: deviceID,
            signedAt: signedAt
        )
        return try await sendAuthProof(proof)
    }

    func makeAuthProof(
        privateKey: Curve25519.Signing.PrivateKey,
        challenge: AuthChallengeMessage,
        deviceID: DeviceID,
        signedAt: Date = Date()
    ) throws -> AuthProofMessage {
        let payload = AuthProofMessage.signingPayload(
            challengeNonce: challenge.nonce,
            challengeIssuedAt: challenge.issuedAt,
            deviceID: deviceID,
            protocolVersion: .current,
            signedAt: signedAt
        )
        let signature = try privateKey.signature(for: payload)

        return AuthProofMessage(
            deviceID: deviceID,
            challengeNonce: challenge.nonce,
            challengeIssuedAt: challenge.issuedAt,
            signedAt: signedAt,
            protocolVersion: .current,
            signature: signature
        )
    }

    func sendAuthProof(_ proof: AuthProofMessage) async throws -> AuthResultMessage {
        try await sendControl(.authProof(proof))
        let envelope = try await nextEnvelope()
        guard case let .authResult(result) = envelope.message else {
            throw NSError(domain: "RawProtocolPeer", code: 2)
        }
        return result
    }

    func sendPairRequest(
        token: PairingToken,
        device: DeviceIdentity,
        signingPrivateKey: Curve25519.Signing.PrivateKey
    ) async throws -> PairResponseMessage {
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: device.id)
        let signature = try signingPrivateKey.signature(for: payload)
        try await sendControl(
            .pairRequest(
                PairRequestMessage(
                    token: token,
                    device: device,
                    publicKey: signingPrivateKey.publicKey.rawRepresentation,
                    signature: signature
                )
            )
        )

        let envelope = try await nextEnvelope()
        guard case let .pairResponse(response) = envelope.message else {
            throw NSError(domain: "RawProtocolPeer", code: 8)
        }
        return response
    }

    func makeControlWireFrame(_ message: ControlMessage) throws -> Data {
        try framedConnection.makeControlWireFrame(.init(message: message))
    }

    func requestAuthChallenge() async throws -> AuthChallengeMessage {
        try await sendControl(.authChallengeRequest(.init()))
        let envelope = try await nextEnvelope()
        guard case let .authChallenge(challenge) = envelope.message else {
            throw NSError(domain: "RawProtocolPeer", code: 7)
        }
        return challenge
    }

    func sendControl(_ message: ControlMessage) async throws {
        try await framedConnection.sendControlEnvelope(.init(message: message))
    }

    func nextEnvelope() async throws -> ControlEnvelope {
        try await withThrowingTaskGroup(of: ControlEnvelope.self) { group in
            group.addTask {
                await self.envelopes.nextEnvelope()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw NSError(domain: "RawProtocolPeer", code: 3)
            }

            let envelope = try await group.next()!
            group.cancelAll()
            return envelope
        }
    }

    func sendRawFrame(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func waitForDisconnect(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if disconnectedState() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return disconnectedState()
    }

    private func disconnectedState() -> Bool {
        disconnectLock.lock()
        defer { disconnectLock.unlock() }
        return isDisconnected
    }
}
