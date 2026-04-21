import Foundation
import APTerminalProtocol

public struct HostSettings: Codable, Equatable, Sendable {
    public static let defaultHostPort: UInt16 = APTerminalConfiguration.defaultHostPort

    public struct SessionLaunchProfile: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public var shellPath: String
        public var defaultWorkingDirectory: String?

        public init(id: String, displayName: String, shellPath: String, defaultWorkingDirectory: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.shellPath = shellPath
            self.defaultWorkingDirectory = defaultWorkingDirectory
        }
    }

    public struct TransportSettings: Codable, Equatable, Sendable {
        public var heartbeatIntervalSeconds: TimeInterval
        public var idleTimeoutSeconds: TimeInterval
        public var maximumPendingTerminalBytes: Int
        public var maximumInboundFrameBytes: Int
        public var maximumBufferedInboundBytes: Int

        public init(
            heartbeatIntervalSeconds: TimeInterval = APTerminalConfiguration.defaultTransportHeartbeatInterval,
            idleTimeoutSeconds: TimeInterval = APTerminalConfiguration.defaultTransportIdleTimeout,
            maximumPendingTerminalBytes: Int = APTerminalConfiguration.defaultTransportMaximumPendingTerminalBytes,
            maximumInboundFrameBytes: Int = APTerminalConfiguration.defaultTransportMaximumInboundFrameBytes,
            maximumBufferedInboundBytes: Int = APTerminalConfiguration.defaultTransportMaximumBufferedInboundBytes
        ) {
            self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
            self.idleTimeoutSeconds = idleTimeoutSeconds
            self.maximumPendingTerminalBytes = maximumPendingTerminalBytes
            self.maximumInboundFrameBytes = maximumInboundFrameBytes
            self.maximumBufferedInboundBytes = maximumBufferedInboundBytes
        }
    }

    public struct ExternalPreviewSettings: Codable, Equatable, Sendable {
        public var chunkBytes: Int
        public var snapshotBytes: Int
        public var snapshotLines: Int
        public var refreshIntervalMilliseconds: UInt64

        public init(
            chunkBytes: Int = APTerminalConfiguration.defaultExternalPreviewChunkBytes,
            snapshotBytes: Int = APTerminalConfiguration.defaultExternalPreviewSnapshotBytes,
            snapshotLines: Int = APTerminalConfiguration.defaultExternalPreviewSnapshotLines,
            refreshIntervalMilliseconds: UInt64 = APTerminalConfiguration.defaultExternalPreviewRefreshIntervalMilliseconds
        ) {
            self.chunkBytes = chunkBytes
            self.snapshotBytes = snapshotBytes
            self.snapshotLines = snapshotLines
            self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
        }
    }

    public var hostDeviceID: DeviceID?
    public var hostPort: UInt16
    public var connectionMode: HostConnectionMode
    public var explicitInternetHost: String?
    public var idleLockTimeoutSeconds: TimeInterval
    public var allowViewOnlyMode: Bool
    public var pasteGuardPolicy: PasteGuardPolicy
    public var lanPairingTokenLifetimeSeconds: TimeInterval
    public var internetPairingTokenLifetimeSeconds: TimeInterval
    public var singleUseBootstrapPayloads: Bool
    public var allowExternalTerminalPreviews: Bool
    public var allowManagedSessionContentPreviews: Bool
    public var sessionLaunchProfiles: [SessionLaunchProfile]
    public var allowedWorkingDirectories: [String]
    public var transport: TransportSettings
    public var externalPreview: ExternalPreviewSettings
    public var displayedAuditEventLimit: Int

    public init(
        hostDeviceID: DeviceID? = nil,
        hostPort: UInt16 = HostSettings.defaultHostPort,
        connectionMode: HostConnectionMode = .lan,
        explicitInternetHost: String? = nil,
        idleLockTimeoutSeconds: TimeInterval = APTerminalConfiguration.defaultIdleLockTimeoutSeconds,
        allowViewOnlyMode: Bool = APTerminalConfiguration.defaultAllowViewOnlyMode,
        pasteGuardPolicy: PasteGuardPolicy = .init(),
        lanPairingTokenLifetimeSeconds: TimeInterval = APTerminalConfiguration.defaultPairingTokenLifetime,
        internetPairingTokenLifetimeSeconds: TimeInterval = APTerminalConfiguration.defaultInternetPairingTokenLifetime,
        singleUseBootstrapPayloads: Bool = true,
        allowExternalTerminalPreviews: Bool? = nil,
        allowManagedSessionContentPreviews: Bool = true,
        sessionLaunchProfiles: [SessionLaunchProfile] = [],
        allowedWorkingDirectories: [String] = [],
        transport: TransportSettings = .init(),
        externalPreview: ExternalPreviewSettings = .init(),
        displayedAuditEventLimit: Int = APTerminalConfiguration.defaultDisplayedAuditEventLimit
    ) {
        self.hostDeviceID = hostDeviceID
        self.hostPort = hostPort
        self.connectionMode = connectionMode
        self.explicitInternetHost = explicitInternetHost
        self.idleLockTimeoutSeconds = idleLockTimeoutSeconds
        self.allowViewOnlyMode = allowViewOnlyMode
        self.pasteGuardPolicy = pasteGuardPolicy
        self.lanPairingTokenLifetimeSeconds = lanPairingTokenLifetimeSeconds
        self.internetPairingTokenLifetimeSeconds = internetPairingTokenLifetimeSeconds
        self.singleUseBootstrapPayloads = singleUseBootstrapPayloads
        self.allowExternalTerminalPreviews = allowExternalTerminalPreviews ?? (connectionMode == .lan)
        self.allowManagedSessionContentPreviews = allowManagedSessionContentPreviews
        self.sessionLaunchProfiles = sessionLaunchProfiles
        self.allowedWorkingDirectories = allowedWorkingDirectories
        self.transport = transport
        self.externalPreview = externalPreview
        self.displayedAuditEventLimit = displayedAuditEventLimit
    }

    private enum CodingKeys: String, CodingKey {
        case hostDeviceID
        case hostPort
        case connectionMode
        case explicitInternetHost
        case idleLockTimeoutSeconds
        case allowViewOnlyMode
        case pasteGuardPolicy
        case pairingTokenLifetimeSeconds
        case lanPairingTokenLifetimeSeconds
        case internetPairingTokenLifetimeSeconds
        case singleUseBootstrapPayloads
        case allowExternalTerminalPreviews
        case allowManagedSessionContentPreviews
        case sessionLaunchProfiles
        case allowedWorkingDirectories
        case transport
        case externalPreview
        case displayedAuditEventLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostDeviceID = try container.decodeIfPresent(DeviceID.self, forKey: .hostDeviceID)
        hostPort = try container.decodeIfPresent(UInt16.self, forKey: .hostPort) ?? Self.defaultHostPort
        connectionMode = try container.decodeIfPresent(HostConnectionMode.self, forKey: .connectionMode) ?? .lan
        explicitInternetHost = try container.decodeIfPresent(String.self, forKey: .explicitInternetHost)
        idleLockTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleLockTimeoutSeconds)
            ?? APTerminalConfiguration.defaultIdleLockTimeoutSeconds
        allowViewOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .allowViewOnlyMode)
            ?? APTerminalConfiguration.defaultAllowViewOnlyMode
        pasteGuardPolicy = try container.decodeIfPresent(PasteGuardPolicy.self, forKey: .pasteGuardPolicy) ?? .init()
        let legacyPairingLifetime = try container.decodeIfPresent(TimeInterval.self, forKey: .pairingTokenLifetimeSeconds)
            ?? APTerminalConfiguration.defaultPairingTokenLifetime
        lanPairingTokenLifetimeSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .lanPairingTokenLifetimeSeconds
        ) ?? legacyPairingLifetime
        internetPairingTokenLifetimeSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .internetPairingTokenLifetimeSeconds
        ) ?? APTerminalConfiguration.defaultInternetPairingTokenLifetime
        singleUseBootstrapPayloads = try container.decodeIfPresent(Bool.self, forKey: .singleUseBootstrapPayloads) ?? true
        allowExternalTerminalPreviews = try container.decodeIfPresent(Bool.self, forKey: .allowExternalTerminalPreviews)
            ?? (connectionMode == .lan)
        allowManagedSessionContentPreviews = try container.decodeIfPresent(Bool.self, forKey: .allowManagedSessionContentPreviews)
            ?? true
        sessionLaunchProfiles = try container.decodeIfPresent([SessionLaunchProfile].self, forKey: .sessionLaunchProfiles) ?? []
        allowedWorkingDirectories = try container.decodeIfPresent([String].self, forKey: .allowedWorkingDirectories) ?? []
        transport = try container.decodeIfPresent(TransportSettings.self, forKey: .transport) ?? .init()
        externalPreview = try container.decodeIfPresent(ExternalPreviewSettings.self, forKey: .externalPreview) ?? .init()
        displayedAuditEventLimit = try container.decodeIfPresent(Int.self, forKey: .displayedAuditEventLimit)
            ?? APTerminalConfiguration.defaultDisplayedAuditEventLimit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hostDeviceID, forKey: .hostDeviceID)
        try container.encode(hostPort, forKey: .hostPort)
        try container.encode(connectionMode, forKey: .connectionMode)
        try container.encodeIfPresent(explicitInternetHost, forKey: .explicitInternetHost)
        try container.encode(idleLockTimeoutSeconds, forKey: .idleLockTimeoutSeconds)
        try container.encode(allowViewOnlyMode, forKey: .allowViewOnlyMode)
        try container.encode(pasteGuardPolicy, forKey: .pasteGuardPolicy)
        try container.encode(lanPairingTokenLifetimeSeconds, forKey: .lanPairingTokenLifetimeSeconds)
        try container.encode(internetPairingTokenLifetimeSeconds, forKey: .internetPairingTokenLifetimeSeconds)
        try container.encode(singleUseBootstrapPayloads, forKey: .singleUseBootstrapPayloads)
        try container.encode(allowExternalTerminalPreviews, forKey: .allowExternalTerminalPreviews)
        try container.encode(allowManagedSessionContentPreviews, forKey: .allowManagedSessionContentPreviews)
        try container.encode(sessionLaunchProfiles, forKey: .sessionLaunchProfiles)
        try container.encode(allowedWorkingDirectories, forKey: .allowedWorkingDirectories)
        try container.encode(transport, forKey: .transport)
        try container.encode(externalPreview, forKey: .externalPreview)
        try container.encode(displayedAuditEventLimit, forKey: .displayedAuditEventLimit)
    }

    public var resolvedPairingTokenLifetimeSeconds: TimeInterval {
        switch connectionMode {
        case .lan:
            return lanPairingTokenLifetimeSeconds
        case .internetVPN:
            return internetPairingTokenLifetimeSeconds
        }
    }
}
