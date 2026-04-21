import Foundation
import XCTest
@testable import APTerminalProtocol

final class PairingBootstrapPayloadTests: XCTestCase {
    func testBootstrapPayloadRoundTripPreservesModeAndEndpointKind() throws {
        let payload = PairingBootstrapPayload(
            hostIdentity: DeviceIdentity(
                id: .random(),
                name: "Test Mac",
                platform: .macOS,
                appVersion: "0.1.0"
            ),
            host: "100.88.1.4",
            port: 61197,
            connectionMode: .internetVPN,
            endpointKind: .overlayVPN,
            token: PairingToken(value: "token", expiresAt: Date(timeIntervalSince1970: 1_000)),
            hostPublicKey: Data(repeating: 0xAB, count: 32)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(PairingBootstrapPayload.self, from: data)

        XCTAssertEqual(decoded.connectionMode, .internetVPN)
        XCTAssertEqual(decoded.endpointKind, .overlayVPN)
    }
}
