import Darwin
import Foundation
import APTerminalProtocol

public struct LocalNetworkAddress: Equatable, Sendable {
    public var interfaceName: String
    public var address: String
    public var isIPv6: Bool
    public var kind: HostEndpointKind

    public init(interfaceName: String, address: String, isIPv6: Bool, kind: HostEndpointKind) {
        self.interfaceName = interfaceName
        self.address = address
        self.isIPv6 = isIPv6
        self.kind = kind
    }
}

public enum HostExposureIssue: Equatable, Sendable {
    case noPrivateLANEndpoint
    case noOverlayEndpoint
    case invalidExplicitInternetEndpoint(String)
    case publicAddressDetected([String])

    public var summary: String {
        switch self {
        case .noPrivateLANEndpoint:
            return "No private LAN address is available for Local Network mode."
        case .noOverlayEndpoint:
            return "No overlay or configured endpoint is available for Private Internet mode."
        case let .invalidExplicitInternetEndpoint(endpoint):
            return "Explicit internet endpoint is not approved for Private Internet mode: \(endpoint)"
        case let .publicAddressDetected(addresses):
            return "Public or global addresses detected: \(addresses.joined(separator: ", "))"
        }
    }
}

public struct HostExposureEvaluation: Equatable, Sendable {
    public var mode: HostConnectionMode
    public var approvedEndpoint: LocalNetworkAddress?
    public var warnings: [HostExposureIssue]
    public var blockingIssues: [HostExposureIssue]

    public init(
        mode: HostConnectionMode,
        approvedEndpoint: LocalNetworkAddress?,
        warnings: [HostExposureIssue],
        blockingIssues: [HostExposureIssue]
    ) {
        self.mode = mode
        self.approvedEndpoint = approvedEndpoint
        self.warnings = warnings
        self.blockingIssues = blockingIssues
    }

    public var canStart: Bool {
        blockingIssues.isEmpty && approvedEndpoint != nil
    }
}

public enum LocalNetworkAddressResolver {
    public static func preferredAddress() -> String? {
        candidateAddresses().first?.address
    }

    public static func preferredAddress(
        for mode: HostConnectionMode,
        explicitInternetHost: String? = nil
    ) -> LocalNetworkAddress? {
        exposureEvaluation(
            for: mode,
            explicitInternetHost: explicitInternetHost,
            candidateAddresses: candidateAddresses()
        ).approvedEndpoint
    }

    public static func listenerBindAddress(
        for mode: HostConnectionMode,
        explicitInternetHost: String? = nil,
        candidateAddresses: [LocalNetworkAddress] = candidateAddresses()
    ) -> LocalNetworkAddress? {
        let evaluation = exposureEvaluation(
            for: mode,
            explicitInternetHost: explicitInternetHost,
            candidateAddresses: candidateAddresses
        )
        guard evaluation.blockingIssues.isEmpty else {
            return nil
        }

        switch mode {
        case .lan:
            return evaluation.approvedEndpoint
        case .internetVPN:
            guard let approvedEndpoint = evaluation.approvedEndpoint else {
                return nil
            }

            guard approvedEndpoint.kind == .configuredInternet else {
                return approvedEndpoint
            }

            if let exactOverlayMatch = candidateAddresses.first(where: {
                $0.address == approvedEndpoint.address && $0.kind == .overlayVPN
            }) {
                return exactOverlayMatch
            }

            return rankAddresses(candidateAddresses, for: .internetVPN)
                .first { $0.kind == .overlayVPN }
        }
    }

    public static func exposureEvaluation(
        for mode: HostConnectionMode,
        explicitInternetHost: String? = nil,
        candidateAddresses: [LocalNetworkAddress] = candidateAddresses()
    ) -> HostExposureEvaluation {
        let rankedAddresses = rankAddresses(candidateAddresses, for: mode)
        let configuredEndpoint = configuredInternetEndpoint(
            from: explicitInternetHost,
            candidateAddresses: candidateAddresses
        )
        let publicAddresses = candidateAddresses.filter { $0.kind == .fallback }.map(\.address).sorted()
        let normalizedExplicitEndpoint = explicitInternetHost?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var warnings: [HostExposureIssue] = []
        if publicAddresses.isEmpty == false {
            warnings.append(.publicAddressDetected(publicAddresses))
        }

        let approvedEndpoint: LocalNetworkAddress?
        var blockingIssues: [HostExposureIssue] = []

        switch mode {
        case .lan:
            approvedEndpoint = rankedAddresses.first { $0.kind == .localNetwork }
            if approvedEndpoint == nil {
                blockingIssues.append(.noPrivateLANEndpoint)
            }
        case .internetVPN:
            approvedEndpoint = configuredEndpoint ?? rankedAddresses.first { $0.kind == .overlayVPN }
            if let normalizedExplicitEndpoint,
               normalizedExplicitEndpoint.isEmpty == false,
               configuredEndpoint == nil {
                blockingIssues.append(.invalidExplicitInternetEndpoint(normalizedExplicitEndpoint))
            } else if let configuredEndpoint,
                      configuredEndpoint.kind == .configuredInternet,
                      configuredEndpoint.address.lowercased().hasSuffix(".ts.net"),
                      rankedAddresses.contains(where: { $0.kind == .overlayVPN }) == false {
                blockingIssues.append(.noOverlayEndpoint)
            } else if approvedEndpoint == nil {
                blockingIssues.append(.noOverlayEndpoint)
            }
        }

        return HostExposureEvaluation(
            mode: mode,
            approvedEndpoint: approvedEndpoint,
            warnings: warnings,
            blockingIssues: blockingIssues
        )
    }

    public static func candidateAddresses() -> [LocalNetworkAddress] {
        var rawInterfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&rawInterfaces) == 0, let firstInterface = rawInterfaces else {
            return []
        }

        defer {
            freeifaddrs(rawInterfaces)
        }

        var addresses: [LocalNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = current {
            defer {
                current = interface.pointee.ifa_next
            }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            guard let rawAddress = interface.pointee.ifa_addr else {
                continue
            }

            let family = Int32(rawAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            guard isReachableInterface(interfaceName) else {
                continue
            }

            let addressLength = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            let result = getnameinfo(
                rawAddress,
                addressLength,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let nulIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
            let addressBytes = hostBuffer[..<nulIndex].map { UInt8(bitPattern: $0) }
            let address = String(decoding: addressBytes, as: UTF8.self)
            if family == AF_INET6, address.hasPrefix("fe80:") {
                continue
            }

            addresses.append(
                LocalNetworkAddress(
                    interfaceName: interfaceName,
                    address: address,
                    isIPv6: family == AF_INET6,
                    kind: classify(interfaceName: interfaceName, address: address, isIPv6: family == AF_INET6)
                )
            )
        }

        let deduplicated = Dictionary(uniqueKeysWithValues: addresses.map { ("\($0.interfaceName)|\($0.address)", $0) })
        return rankAddresses(Array(deduplicated.values), for: .lan)
    }

    public static func rankAddresses(
        _ addresses: [LocalNetworkAddress],
        for mode: HostConnectionMode
    ) -> [LocalNetworkAddress] {
        addresses.sorted { lhs, rhs in
            let lhsPriority = priority(for: lhs, mode: mode)
            let rhsPriority = priority(for: rhs, mode: mode)

            if lhsPriority == rhsPriority {
                return lhs.address < rhs.address
            }

            return lhsPriority > rhsPriority
        }
    }

    private static func isReachableInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") ||
            name.hasPrefix("utun") || name.localizedCaseInsensitiveContains("tailscale")
    }

    private static func priority(for address: LocalNetworkAddress, mode: HostConnectionMode) -> Int {
        var priority = 0

        switch mode {
        case .lan:
            switch address.kind {
            case .localNetwork:
                priority += 400
            case .overlayVPN:
                priority += 150
            case .configuredInternet:
                priority += 100
            case .fallback:
                priority += 0
            }
        case .internetVPN:
            switch address.kind {
            case .configuredInternet:
                priority += 900
            case .overlayVPN:
                priority += 800
            case .localNetwork:
                priority += 400
            case .fallback:
                priority += 0
            }
        }

        if address.interfaceName == "en0" {
            priority += 100
        } else if address.interfaceName == "en1" {
            priority += 90
        } else if address.interfaceName.hasPrefix("en") {
            priority += 80
        } else if address.interfaceName.hasPrefix("utun") ||
            address.interfaceName.localizedCaseInsensitiveContains("tailscale") {
            priority += 85
        } else if address.interfaceName.hasPrefix("bridge") {
            priority += 70
        }

        if address.isIPv6 == false {
            priority += 20
        }

        if isPrivateIPv4(address.address) {
            priority += 200
        } else if isLinkLocalIPv4(address.address) {
            priority -= 200
        }

        return priority
    }

    private static func classify(interfaceName: String, address: String, isIPv6: Bool) -> HostEndpointKind {
        if interfaceName.hasPrefix("utun") ||
            interfaceName.localizedCaseInsensitiveContains("tailscale") ||
            isTailscaleIPv4(address) ||
            isTailscaleIPv6(address) {
            return .overlayVPN
        }

        if isPrivateIPv4(address) || (isIPv6 && address.hasPrefix("fd")) {
            return .localNetwork
        }

        return .fallback
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        switch (octets[0], octets[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

    private static func isLinkLocalIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        return octets[0] == 169 && octets[1] == 254
    }

    private static func isTailscaleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        let firstOctet = octets[0]
        let secondOctet = octets[1]
        guard firstOctet == 100 else {
            return false
        }

        return secondOctet >= 64 && secondOctet <= 127
    }

    private static func isTailscaleIPv6(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func configuredInternetEndpoint(
        from explicitInternetHost: String?,
        candidateAddresses: [LocalNetworkAddress]
    ) -> LocalNetworkAddress? {
        guard let explicitInternetHost else {
            return nil
        }

        let normalized = explicitInternetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return nil
        }

        if normalized.lowercased().hasSuffix(".ts.net") == false {
            let matchingCandidate = candidateAddresses.first {
                $0.address == normalized && $0.kind == .overlayVPN
            }
            let approvedLiteral = matchingCandidate != nil ||
                isTailscaleIPv4(normalized) ||
                isTailscaleIPv6(normalized)
            guard approvedLiteral else {
                return nil
            }
        }

        return LocalNetworkAddress(
            interfaceName: "configured",
            address: normalized,
            isIPv6: normalized.contains(":"),
            kind: .configuredInternet
        )
    }
}
