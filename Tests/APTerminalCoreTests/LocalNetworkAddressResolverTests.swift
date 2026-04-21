import XCTest
@testable import APTerminalCore
@testable import APTerminalProtocol

final class LocalNetworkAddressResolverTests: XCTestCase {
    func testInternetModePrefersOverlayAddressOverLan() {
        let addresses = [
            LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
            LocalNetworkAddress(interfaceName: "utun4", address: "100.88.1.4", isIPv6: false, kind: .overlayVPN),
        ]

        let ranked = LocalNetworkAddressResolver.rankAddresses(addresses, for: .internetVPN)

        XCTAssertEqual(ranked.first?.address, "100.88.1.4")
        XCTAssertEqual(ranked.first?.kind, .overlayVPN)
    }

    func testLanModePrefersPrivateLanAddressOverOverlay() {
        let addresses = [
            LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
            LocalNetworkAddress(interfaceName: "utun4", address: "100.88.1.4", isIPv6: false, kind: .overlayVPN),
        ]

        let ranked = LocalNetworkAddressResolver.rankAddresses(addresses, for: .lan)

        XCTAssertEqual(ranked.first?.address, "192.168.1.20")
        XCTAssertEqual(ranked.first?.kind, .localNetwork)
    }

    func testInternetModeUsesTailscaleMagicDNSEndpointWhenProvided() {
        let endpoint = LocalNetworkAddressResolver.preferredAddress(
            for: .internetVPN,
            explicitInternetHost: "tailnet.example.ts.net"
        )

        XCTAssertEqual(endpoint?.address, "tailnet.example.ts.net")
        XCTAssertEqual(endpoint?.kind, .configuredInternet)
    }

    func testInternetModeUsesOverlayBindAddressWhenMagicDNSEndpointProvided() {
        let addresses = [
            LocalNetworkAddress(interfaceName: "utun4", address: "100.88.1.4", isIPv6: false, kind: .overlayVPN),
            LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
        ]

        let bindAddress = LocalNetworkAddressResolver.listenerBindAddress(
            for: .internetVPN,
            explicitInternetHost: "tailnet.example.ts.net",
            candidateAddresses: addresses
        )

        XCTAssertEqual(bindAddress?.address, "100.88.1.4")
        XCTAssertEqual(bindAddress?.kind, .overlayVPN)
    }

    func testInternetModeBlocksExplicitPublicIPAddress() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .internetVPN,
            explicitInternetHost: "203.0.113.10",
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "utun4", address: "100.88.1.4", isIPv6: false, kind: .overlayVPN),
            ]
        )

        XCTAssertFalse(evaluation.canStart)
        XCTAssertEqual(
            evaluation.blockingIssues,
            [.invalidExplicitInternetEndpoint("203.0.113.10")]
        )
    }

    func testInternetModeAllowsExplicitOverlayLiteral() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .internetVPN,
            explicitInternetHost: "100.88.1.4",
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "utun4", address: "100.88.1.4", isIPv6: false, kind: .overlayVPN),
            ]
        )

        XCTAssertTrue(evaluation.canStart)
        XCTAssertEqual(evaluation.approvedEndpoint?.address, "100.88.1.4")
        XCTAssertEqual(evaluation.approvedEndpoint?.kind, .configuredInternet)
    }

    func testLanModeBlocksWhenNoPrivateEndpointExists() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .lan,
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "en0", address: "203.0.113.10", isIPv6: false, kind: .fallback),
            ]
        )

        XCTAssertFalse(evaluation.canStart)
        XCTAssertEqual(evaluation.blockingIssues, [.noPrivateLANEndpoint])
    }

    func testInternetModeBlocksWhenNoOverlayOrConfiguredEndpointExists() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .internetVPN,
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
            ]
        )

        XCTAssertFalse(evaluation.canStart)
        XCTAssertEqual(evaluation.blockingIssues, [.noOverlayEndpoint])
    }

    func testInternetModeBlocksMagicDNSEndpointWithoutOverlayInterface() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .internetVPN,
            explicitInternetHost: "tailnet.example.ts.net",
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
            ]
        )

        XCTAssertFalse(evaluation.canStart)
        XCTAssertEqual(evaluation.blockingIssues, [.noOverlayEndpoint])
        XCTAssertNil(
            LocalNetworkAddressResolver.listenerBindAddress(
                for: .internetVPN,
                explicitInternetHost: "tailnet.example.ts.net",
                candidateAddresses: [
                    LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
                ]
            )
        )
    }

    func testExposureEvaluationFlagsUnsafeFallbackAddresses() {
        let evaluation = LocalNetworkAddressResolver.exposureEvaluation(
            for: .lan,
            candidateAddresses: [
                LocalNetworkAddress(interfaceName: "en0", address: "192.168.1.20", isIPv6: false, kind: .localNetwork),
                LocalNetworkAddress(interfaceName: "en0", address: "2001:db8::10", isIPv6: true, kind: .fallback),
            ]
        )

        XCTAssertTrue(evaluation.canStart)
        XCTAssertEqual(evaluation.approvedEndpoint?.address, "192.168.1.20")
        XCTAssertEqual(evaluation.warnings, [.publicAddressDetected(["2001:db8::10"])])
    }
}
