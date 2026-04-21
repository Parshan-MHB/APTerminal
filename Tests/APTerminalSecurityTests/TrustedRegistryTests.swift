import Foundation
import XCTest
@testable import APTerminalProtocol
@testable import APTerminalSecurity

final class TrustedRegistryTests: XCTestCase {
    func testTrustedDeviceRegistryPurgesExpiredRecords() async {
        let expiredRecord = TrustedDeviceRecord(
            identity: DeviceIdentity(
                id: .random(),
                name: "Expired iPhone",
                platform: .iOS,
                appVersion: "0.1.0"
            ),
            publicKeyData: Data(repeating: 0x01, count: 32),
            pairedAt: Date(timeIntervalSinceNow: -1_000),
            lastSeenAt: nil,
            expiresAt: Date(timeIntervalSinceNow: -10)
        )
        let registry = TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore(devices: [expiredRecord]))

        let devices = await registry.allDevices()
        let record = await registry.record(for: expiredRecord.identity.id)
        let isTrusted = await registry.isTrusted(deviceID: expiredRecord.identity.id)

        XCTAssertTrue(devices.isEmpty)
        XCTAssertNil(record)
        XCTAssertFalse(isTrusted)
    }

    func testTrustedHostRegistryPurgesExpiredRecords() async {
        let expiredHost = TrustedHostRecord(
            host: DeviceIdentity(
                id: .random(),
                name: "Expired Mac",
                platform: .macOS,
                appVersion: "0.1.0"
            ),
            hostAddress: "100.64.0.12",
            port: 61197,
            connectionMode: .internetVPN,
            endpointKind: .overlayVPN,
            publicKeyData: Data(repeating: 0x02, count: 32),
            pairedAt: Date(timeIntervalSinceNow: -1_000),
            lastSeenAt: nil,
            expiresAt: Date(timeIntervalSinceNow: -10)
        )
        let registry = TrustedHostRegistry(store: InMemoryTrustedHostStore(hosts: [expiredHost]))

        let hosts = await registry.allHosts()
        let record = await registry.record(for: expiredHost.host.id)

        XCTAssertTrue(hosts.isEmpty)
        XCTAssertNil(record)
    }
}
