import CryptoKit
import Foundation
import Network
import XCTest
@testable import APTerminalProtocol
@testable import APTerminalTransport

final class FramedConnectionTests: XCTestCase {
    func testTerminalOutputBackpressureRejectsWhenPendingBytesExceedLimit() async throws {
        let senderState = PendingSenderState()

        let connection = NWConnection(host: "127.0.0.1", port: 6553, using: .tcp)
        let framed = FramedConnection(
            connection: connection,
            label: "com.apterminal.tests.transport",
            configuration: .init(heartbeatInterval: 15, idleTimeout: 45, maximumPendingTerminalBytes: 350),
            frameSender: { _, completion in
                senderState.append(completion)
            }
        )

        let chunk = TerminalStreamChunk(
            sessionID: .random(),
            direction: .output,
            sequenceNumber: 1,
            data: Data(repeating: 0x61, count: 128)
        )

        async let firstSend: Void = framed.sendTerminalChunk(chunk, kind: .terminalOutput)
        await Task.yield()

        do {
            try await framed.sendTerminalChunk(chunk, kind: .terminalOutput)
            XCTFail("Expected terminal output backpressure to reject the second send")
        } catch let error as FramedConnectionError {
            XCTAssertEqual(error, .outboundBackpressureExceeded(limit: 350))
        }

        let pendingCompletions = senderState.pendingCompletions
        XCTAssertEqual(pendingCompletions.count, 1)

        pendingCompletions.forEach { $0(nil) }
        try await firstSend
    }

    func testSecureTransportDecodeRejectsCorruptedCiphertext() throws {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let originalFrame = try SecureTransportCodec.encodeFrame(
            kind: .control,
            payload: Data("hello".utf8),
            sequenceNumber: 0,
            key: key
        )

        var corruptedFrame = originalFrame
        corruptedFrame[corruptedFrame.count - 1] ^= 0xFF

        XCTAssertThrowsError(
            try SecureTransportCodec.decodeFrame(
                corruptedFrame,
                expectedSequenceNumber: 0,
                key: key
            )
        ) { error in
            XCTAssertEqual(error as? SecureTransportError, .decryptFailed)
        }
    }
}

private final class PendingSenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [(@Sendable (Error?) -> Void)] = []

    func append(_ completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        completions.append(completion)
    }

    var pendingCompletions: [(@Sendable (Error?) -> Void)] {
        lock.lock()
        defer { lock.unlock() }
        return completions
    }
}
