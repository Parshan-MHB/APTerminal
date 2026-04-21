import Foundation
import Network
import CryptoKit
import APTerminalProtocol
import APTerminalProtocolCodec

public enum FramedConnectionError: Error, Equatable {
    case disconnected
    case idleTimeout
    case outboundBackpressureExceeded(limit: Int)
    case secureTransportFailed(String)
}

public struct FramedConnectionConfiguration: Sendable {
    public var heartbeatInterval: TimeInterval
    public var idleTimeout: TimeInterval
    public var maximumPendingTerminalBytes: Int
    public var maximumInboundFrameBytes: Int
    public var maximumBufferedInboundBytes: Int

    public init(
        heartbeatInterval: TimeInterval = APTerminalConfiguration.defaultTransportHeartbeatInterval,
        idleTimeout: TimeInterval = APTerminalConfiguration.defaultTransportIdleTimeout,
        maximumPendingTerminalBytes: Int = APTerminalConfiguration.defaultTransportMaximumPendingTerminalBytes,
        maximumInboundFrameBytes: Int = APTerminalConfiguration.defaultTransportMaximumInboundFrameBytes,
        maximumBufferedInboundBytes: Int = APTerminalConfiguration.defaultTransportMaximumBufferedInboundBytes
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.idleTimeout = idleTimeout
        self.maximumPendingTerminalBytes = maximumPendingTerminalBytes
        self.maximumInboundFrameBytes = maximumInboundFrameBytes
        self.maximumBufferedInboundBytes = maximumBufferedInboundBytes
    }
}

public final class FramedConnection: @unchecked Sendable {
    public typealias FrameSender = @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void

    public let connection: NWConnection

    public var onStateChange: (@Sendable (NWConnection.State) -> Void)?
    public var onControlEnvelope: (@Sendable (ControlEnvelope) -> Void)?
    public var onTerminalInputChunk: (@Sendable (TerminalStreamChunk) -> Void)?
    public var onTerminalOutputChunk: (@Sendable (TerminalStreamChunk) -> Void)?
    public var onHeartbeat: (@Sendable () -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    private let configuration: FramedConnectionConfiguration
    private let frameSender: FrameSender
    private let stateLock = NSLock()
    private lazy var accumulator = FrameStreamAccumulator(
        maximumFrameBodyBytes: configuration.maximumInboundFrameBytes,
        maximumBufferedBytes: configuration.maximumBufferedInboundBytes
    )
    private struct SecureSessionState {
        let outboundKey: SymmetricKey
        let inboundKey: SymmetricKey
        var nextOutboundSequence: UInt64 = 0
        var nextInboundSequence: UInt64 = 0
    }

    private var heartbeatTimer: DispatchSourceTimer?
    private var lastInboundAt = Date()
    private var pendingTerminalBytes = 0
    private var secureSessionState: SecureSessionState?

    public init(
        connection: NWConnection,
        label: String,
        configuration: FramedConnectionConfiguration = .init(),
        frameSender: FrameSender? = nil
    ) {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
        self.configuration = configuration
        self.frameSender = frameSender ?? { [connection] frame, completion in
            connection.send(content: frame, completion: .contentProcessed { error in
                completion(error)
            })
        }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)

            switch state {
            case .ready:
                self?.startHeartbeatTimer()
                self?.receiveNext()
            case let .failed(error):
                self?.stopHeartbeatTimer()
                self?.onError?(error)
                self?.onDisconnect?()
            case .cancelled:
                self?.stopHeartbeatTimer()
                self?.onDisconnect?()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    public func cancel() {
        stopHeartbeatTimer()
        connection.cancel()
    }

    public func sendControlEnvelope(_ envelope: ControlEnvelope) async throws {
        let payload = try ControlMessageCodec.encodeEnvelope(envelope)
        try await sendFrame(kind: .control, payload: payload)
    }

    public func sendTerminalChunk(_ chunk: TerminalStreamChunk, kind: FrameKind) async throws {
        let payload = try TerminalStreamChunkCodec.encode(chunk)
        try await sendFrame(kind: kind, payload: payload)
    }

    public func sendHeartbeat() async throws {
        try await sendFrame(kind: .heartbeat, payload: Data())
    }

    public func activateSecureSession(keys: SecureSessionKeys) {
        stateLock.lock()
        defer { stateLock.unlock() }
        secureSessionState = SecureSessionState(
            outboundKey: keys.outboundKey,
            inboundKey: keys.inboundKey
        )
    }

    public func secureSessionEstablished() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return secureSessionState != nil
    }

    private func sendFrame(kind: FrameKind, payload: Data) async throws {
        let frame = try makeWireFrame(kind: kind, payload: payload)
        try reservePendingCapacityIfNeeded(kind: kind, frameSize: frame.count)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            frameSender(frame) { [weak self] error in
                self?.releasePendingCapacityIfNeeded(kind: kind, frameSize: frame.count)

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func makeControlWireFrame(_ envelope: ControlEnvelope) throws -> Data {
        let payload = try ControlMessageCodec.encodeEnvelope(envelope)
        return try makeWireFrame(kind: .control, payload: payload)
    }

    private func makeWireFrame(kind: FrameKind, payload: Data) throws -> Data {
        stateLock.lock()
        defer { stateLock.unlock() }

        if var secureSessionState {
            if kind == .secureTransport {
                throw FramedConnectionError.secureTransportFailed("Nested secure transport frame")
            }

            let securePayload = try SecureTransportCodec.encodeFrame(
                kind: kind,
                payload: payload,
                sequenceNumber: secureSessionState.nextOutboundSequence,
                key: secureSessionState.outboundKey
            )
            secureSessionState.nextOutboundSequence += 1
            self.secureSessionState = secureSessionState
            return FrameCodec.encodeFrame(kind: .secureTransport, payload: securePayload)
        }

        return FrameCodec.encodeFrame(kind: kind, payload: payload)
    }

    private func reservePendingCapacityIfNeeded(kind: FrameKind, frameSize: Int) throws {
        guard kind == .terminalOutput else {
            return
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        let nextPendingBytes = pendingTerminalBytes + frameSize
        guard nextPendingBytes <= configuration.maximumPendingTerminalBytes else {
            throw FramedConnectionError.outboundBackpressureExceeded(limit: configuration.maximumPendingTerminalBytes)
        }

        pendingTerminalBytes = nextPendingBytes
    }

    private func releasePendingCapacityIfNeeded(kind: FrameKind, frameSize: Int) {
        guard kind == .terminalOutput else {
            return
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        pendingTerminalBytes = max(0, pendingTerminalBytes - frameSize)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let error {
                self.onError?(error)
                self.onDisconnect?()
                return
            }

            if let data, data.isEmpty == false {
                self.lastInboundAt = Date()
                do {
                    let frames = try self.accumulator.append(data)
                    try self.dispatch(frames: frames)
                } catch {
                    self.onError?(error)
                    self.cancel()
                    self.onDisconnect?()
                    return
                }
            }

            if isComplete {
                self.onDisconnect?()
                return
            }

            self.receiveNext()
        }
    }

    private func dispatch(frames: [DecodedFrame]) throws {
        for frame in frames {
            switch try normalizedFrameKindAndPayload(for: frame) {
            case let (.control, payload):
                let envelope = try ControlMessageCodec.decodeEnvelope(payload)
                onControlEnvelope?(envelope)
            case let (.terminalInput, payload):
                let chunk = try TerminalStreamChunkCodec.decode(payload)
                onTerminalInputChunk?(chunk)
            case let (.terminalOutput, payload):
                let chunk = try TerminalStreamChunkCodec.decode(payload)
                onTerminalOutputChunk?(chunk)
            case (.heartbeat, _):
                onHeartbeat?()
            case (.secureTransport, _):
                throw FramedConnectionError.secureTransportFailed("Unexpected secure transport payload")
            }
        }
    }

    private func normalizedFrameKindAndPayload(for frame: DecodedFrame) throws -> (FrameKind, Data) {
        switch frame.header.kind {
        case .secureTransport:
            stateLock.lock()
            defer { stateLock.unlock() }

            guard var secureSessionState else {
                throw SecureTransportError.secureSessionNotEstablished
            }

            let decoded = try SecureTransportCodec.decodeFrame(
                frame.payload,
                expectedSequenceNumber: secureSessionState.nextInboundSequence,
                key: secureSessionState.inboundKey
            )
            secureSessionState.nextInboundSequence += 1
            self.secureSessionState = secureSessionState
            return (decoded.kind.frameKind, decoded.payload)
        case .control, .terminalInput, .terminalOutput, .heartbeat:
            guard secureSessionEstablished() == false else {
                throw SecureTransportError.plaintextFrameRejected(frame.header.kind)
            }
            return (frame.header.kind, frame.payload)
        }
    }

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.heartbeatInterval, repeating: configuration.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            if Date().timeIntervalSince(self.lastInboundAt) > self.configuration.idleTimeout {
                self.onError?(FramedConnectionError.idleTimeout)
                self.cancel()
                self.onDisconnect?()
                return
            }

            let wireFrame: Data
            do {
                wireFrame = try self.makeWireFrame(kind: .heartbeat, payload: Data())
            } catch {
                self.onError?(error)
                self.cancel()
                self.onDisconnect?()
                return
            }

            self.connection.send(content: wireFrame, completion: .contentProcessed { error in
                if let error {
                    self.onError?(error)
                }
            })
        }

        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}
