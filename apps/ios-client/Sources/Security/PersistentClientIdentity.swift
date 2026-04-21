import CryptoKit
import Foundation
import UIKit
import APTerminalProtocol
import APTerminalSecurity

struct PersistentClientIdentity {
    let identity: DeviceIdentity
    let privateKey: Curve25519.Signing.PrivateKey

    @MainActor
    static func load(
        userDefaults: UserDefaults = .standard,
        keyStore: SigningKeyStore = KeychainSigningKeyStore(
            service: APTerminalConfiguration.iosClientSigningKeyService,
            account: APTerminalConfiguration.defaultKeychainAccount
        )
    ) -> PersistentClientIdentity {
        let deviceIDDefaultsKey = "client.device-id"
        let privateKey = (try? keyStore.loadOrCreatePrivateKey()) ?? Curve25519.Signing.PrivateKey()

        let deviceID: DeviceID
        if let rawValue = userDefaults.string(forKey: deviceIDDefaultsKey), rawValue.isEmpty == false {
            deviceID = DeviceID(rawValue: rawValue)
        } else {
            let createdID = DeviceID.random()
            userDefaults.set(createdID.rawValue, forKey: deviceIDDefaultsKey)
            deviceID = createdID
        }

        return PersistentClientIdentity(
            identity: DeviceIdentity(
                id: deviceID,
                name: UIDevice.current.name,
                platform: .iOS,
                appVersion: APTerminalAppMetadata.currentAppVersion()
            ),
            privateKey: privateKey
        )
    }
}
