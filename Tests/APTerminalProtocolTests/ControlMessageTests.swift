import Foundation
import XCTest
@testable import APTerminalProtocol

final class ControlMessageTests: XCTestCase {
    func testHelloRoundTripPreservesPayload() throws {
        let message = ControlMessage.hello(
            HelloMessage(
                role: .iosClient,
                device: DeviceIdentity(
                    id: .random(),
                    name: "User iPhone",
                    platform: .iOS,
                    appVersion: "0.1.0"
                ),
                supportedVersions: [.v1]
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    func testCreateSessionRoundTripPreservesOptionalFields() throws {
        let message = ControlMessage.createSession(
            CreateSessionRequest(
                shellPath: "/bin/zsh",
                workingDirectory: "/Users",
                initialSize: SessionWindowSize(rows: 40, columns: 120)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    func testSecureSessionReadyRoundTripPreservesProtectedMetadata() throws {
        let message = ControlMessage.secureSessionReady(
            SecureSessionReadyMessage(
                establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                hostIdentity: DeviceIdentity(
                    id: .random(),
                    name: "User Mac",
                    platform: .macOS,
                    appVersion: "1.0.0"
                ),
                connectionMode: .internetVPN,
                endpointKind: .overlayVPN,
                previewAccessModes: [.internetVPN]
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }
}
