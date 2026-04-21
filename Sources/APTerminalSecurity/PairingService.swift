import CryptoKit
import Foundation
import APTerminalProtocol

public enum PairingValidationError: Error, Equatable {
    case tokenMissing
    case tokenExpired
    case invalidSignature
    case invalidPublicKey
}

public actor PairingService {
    public static let defaultTokenLifetime: TimeInterval = APTerminalConfiguration.defaultPairingTokenLifetime

    private var issuedTokens: [String: Date] = [:]

    public init() {}

    public func createToken(
        lifetime: TimeInterval = defaultTokenLifetime,
        invalidatingExisting: Bool = false
    ) -> PairingToken {
        if invalidatingExisting {
            issuedTokens.removeAll()
        }
        let expiresAt = Date().addingTimeInterval(lifetime)
        let token = PairingToken(value: UUID().uuidString.lowercased(), expiresAt: expiresAt)
        issuedTokens[token.value] = expiresAt
        return token
    }

    public func validate(_ request: PairRequestMessage) throws {
        guard let expiration = issuedTokens.removeValue(forKey: request.token.value) else {
            throw PairingValidationError.tokenMissing
        }

        guard expiration > Date() else {
            throw PairingValidationError.tokenExpired
        }

        let publicKey: Curve25519.Signing.PublicKey

        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: request.publicKey)
        } catch {
            throw PairingValidationError.invalidPublicKey
        }

        let payload = Self.signingPayload(tokenValue: request.token.value, deviceID: request.device.id)

        guard publicKey.isValidSignature(request.signature, for: payload) else {
            throw PairingValidationError.invalidSignature
        }
    }

    public static func signingPayload(tokenValue: String, deviceID: DeviceID) -> Data {
        Data("\(tokenValue):\(deviceID.rawValue)".utf8)
    }
}
