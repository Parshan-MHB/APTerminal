import Foundation

public enum PeerRole: String, Codable, Sendable {
    case macCompanion
    case iosClient
}

public enum DevicePlatform: String, Codable, Sendable {
    case macOS
    case iOS
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var id: DeviceID
    public var name: String
    public var platform: DevicePlatform
    public var appVersion: String

    public init(
        id: DeviceID,
        name: String,
        platform: DevicePlatform,
        appVersion: String
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}

public enum HostConnectionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case lan
    case internetVPN = "internet-vpn"

    public var displayName: String {
        switch self {
        case .lan:
            return "Local Network"
        case .internetVPN:
            return "Private Internet (Tailscale)"
        }
    }
}

public enum HostEndpointKind: String, Codable, Sendable {
    case configuredInternet
    case overlayVPN
    case localNetwork
    case fallback

    public var displayName: String {
        switch self {
        case .configuredInternet:
            return "Configured Endpoint"
        case .overlayVPN:
            return "Overlay VPN"
        case .localNetwork:
            return "Local Network"
        case .fallback:
            return "Fallback"
        }
    }
}

public enum PairingStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case expired
}

public enum AuthenticationStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case stale
    case replayed
}

public struct PairingToken: Codable, Equatable, Sendable {
    public var value: String
    public var expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

public enum AuditEventKind: String, Codable, Sendable {
    case devicePaired
    case deviceRevoked
    case previewAccessGranted
    case previewAccessRevoked
    case previewAccessDenied
    case previewAccessUsed
    case connectionAccepted
    case connectionDenied
    case authChallengeIssued
    case authProofAccepted
    case authProofRejected
    case sessionAttached
    case sessionDetached
    case remoteSessionCreated
    case externalPreviewsEnabled
    case externalPreviewsDisabled
    case externalPreviewAttached
}
