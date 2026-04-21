import CryptoKit
import XCTest
@testable import APTerminalProtocol
@testable import APTerminalSecurity

final class PairingServiceTests: XCTestCase {
    func testValidateAcceptsFreshSignedToken() async throws {
        let service = PairingService()
        let token = await service.createToken(lifetime: 60)
        let device = DeviceIdentity(
            id: .random(),
            name: "Test iPhone",
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: device.id)
        let signature = try privateKey.signature(for: payload)
        let request = PairRequestMessage(
            token: token,
            device: device,
            publicKey: privateKey.publicKey.rawRepresentation,
            signature: signature
        )

        try await service.validate(request)
    }

    func testValidateRejectsTokenReuse() async throws {
        let service = PairingService()
        let token = await service.createToken(lifetime: 60)
        let device = DeviceIdentity(
            id: .random(),
            name: "Test iPhone",
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: device.id)
        let signature = try privateKey.signature(for: payload)
        let request = PairRequestMessage(
            token: token,
            device: device,
            publicKey: privateKey.publicKey.rawRepresentation,
            signature: signature
        )

        try await service.validate(request)

        do {
            try await service.validate(request)
            XCTFail("Expected reused pairing token to be rejected")
        } catch let error as PairingValidationError {
            XCTAssertEqual(error, .tokenMissing)
        }
    }

    func testValidateRejectsExpiredToken() async throws {
        let service = PairingService()
        let token = await service.createToken(lifetime: -1)
        let device = DeviceIdentity(
            id: .random(),
            name: "Test iPhone",
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: device.id)
        let signature = try privateKey.signature(for: payload)
        let request = PairRequestMessage(
            token: token,
            device: device,
            publicKey: privateKey.publicKey.rawRepresentation,
            signature: signature
        )

        do {
            try await service.validate(request)
            XCTFail("Expected expired pairing token to be rejected")
        } catch let error as PairingValidationError {
            XCTAssertEqual(error, .tokenExpired)
        }
    }

    func testInvalidSignatureConsumesToken() async throws {
        let service = PairingService()
        let token = await service.createToken(lifetime: 60)
        let device = DeviceIdentity(
            id: .random(),
            name: "Test iPhone",
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let trustedKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let payload = PairingService.signingPayload(tokenValue: token.value, deviceID: device.id)
        let signature = try wrongKey.signature(for: payload)
        let request = PairRequestMessage(
            token: token,
            device: device,
            publicKey: trustedKey.publicKey.rawRepresentation,
            signature: signature
        )

        do {
            try await service.validate(request)
            XCTFail("Expected invalid signature to be rejected")
        } catch let error as PairingValidationError {
            XCTAssertEqual(error, .invalidSignature)
        }

        do {
            try await service.validate(request)
            XCTFail("Expected token to be invalidated after a failed attempt")
        } catch let error as PairingValidationError {
            XCTAssertEqual(error, .tokenMissing)
        }
    }

    func testInvalidatingExistingTokensLeavesOnlyMostRecentBootstrapValid() async throws {
        let service = PairingService()
        let firstToken = await service.createToken(lifetime: 60)
        let secondToken = await service.createToken(lifetime: 60, invalidatingExisting: true)
        let device = DeviceIdentity(
            id: .random(),
            name: "Bootstrap iPhone",
            platform: .iOS,
            appVersion: "0.1.0"
        )
        let privateKey = Curve25519.Signing.PrivateKey()

        let firstPayload = PairingService.signingPayload(tokenValue: firstToken.value, deviceID: device.id)
        let firstSignature = try privateKey.signature(for: firstPayload)
        let firstRequest = PairRequestMessage(
            token: firstToken,
            device: device,
            publicKey: privateKey.publicKey.rawRepresentation,
            signature: firstSignature
        )

        do {
            try await service.validate(firstRequest)
            XCTFail("Expected previous token to be invalidated")
        } catch let error as PairingValidationError {
            XCTAssertEqual(error, .tokenMissing)
        }

        let secondPayload = PairingService.signingPayload(tokenValue: secondToken.value, deviceID: device.id)
        let secondSignature = try privateKey.signature(for: secondPayload)
        let secondRequest = PairRequestMessage(
            token: secondToken,
            device: device,
            publicKey: privateKey.publicKey.rawRepresentation,
            signature: secondSignature
        )

        try await service.validate(secondRequest)
    }
}
