import Foundation

public enum APTerminalConfiguration {
    public static let appName = "APTerminal"
    public static let defaultAppVersion = "0.1.0"
    public static let defaultHostPort: UInt16 = 61197
    public static let defaultIdleLockTimeoutSeconds: TimeInterval = 300
    public static let defaultAllowViewOnlyMode = true
    public static let defaultTrustLifetime: TimeInterval = 24 * 60 * 60
    public static let defaultPairingTokenLifetime: TimeInterval = 24 * 60 * 60
    public static let defaultInternetPairingTokenLifetime: TimeInterval = 30 * 60
    public static let defaultTransportHeartbeatInterval: TimeInterval = 15
    public static let defaultTransportIdleTimeout: TimeInterval = 45
    public static let defaultTransportMaximumPendingTerminalBytes = 8 * 1024 * 1024
    public static let defaultTransportMaximumInboundFrameBytes = 256 * 1024
    public static let defaultTransportMaximumBufferedInboundBytes = 512 * 1024
    public static let defaultAuthenticationChallengeLifetime: TimeInterval = 15
    public static let defaultAuthenticationProofFreshnessWindow: TimeInterval = 30
    public static let defaultSecureSessionOfferLifetime: TimeInterval = 15
    public static let defaultRequestTimeoutSeconds: TimeInterval = 10
    public static let defaultSecureSessionReplyPollIntervalMilliseconds: UInt64 = 10
    public static let defaultHelloRateLimit = 6
    public static let defaultPairRateLimit = 4
    public static let defaultSessionControlRateLimit = 30
    public static let defaultCreateSessionRateLimit = 4
    public static let defaultAttachSessionRateLimit = 8
    public static let defaultRateLimitWindowSeconds: TimeInterval = 10
    public static let defaultExternalPreviewChunkBytes = 4 * 1024
    public static let defaultExternalPreviewSnapshotBytes = 256 * 1024
    public static let defaultExternalPreviewSnapshotLines = 4_000
    public static let defaultExternalPreviewRefreshIntervalMilliseconds: UInt64 = 400
    public static let defaultExternalPreviewInitialSnapshotDelayMilliseconds: UInt64 = 75
    public static let defaultExternalPreviewLoadTimeoutMilliseconds: UInt64 = 750
    public static let defaultHostStartupBindRetryCount = 8
    public static let defaultHostStartupBindRetryDelayMilliseconds: UInt64 = 250
    public static let defaultHostStartupTimeoutSeconds: TimeInterval = 5
    public static let defaultHostStartupPollIntervalMilliseconds: UInt64 = 100
    public static let defaultHostStopTimeoutSeconds: TimeInterval = 3
    public static let defaultHostStopPollIntervalMilliseconds: UInt64 = 50
    public static let defaultHostRefreshIntervalSeconds: TimeInterval = 2
    public static let defaultPeerStopDelayMilliseconds: UInt64 = 50
    public static let defaultAutoReconnectDelayMilliseconds: UInt64 = 1_500
    public static let defaultLocalNetworkAuthorizationTimeoutSeconds: TimeInterval = 12
    public static let defaultDisplayedAuditEventLimit = 100
    public static let defaultKeychainAccount = "default"
    public static let trustedDevicesKeychainService = "com.apterminal.trusted-devices"
    public static let signingKeyKeychainService = "com.apterminal.signing-key"
    public static let iosClientSigningKeyService = "com.apterminal.ios.client-signing-key"
    public static let hostSettingsFileName = "host-settings.json"
    public static let trustedHostsFileName = "trusted-hosts.json"
    public static let auditLogFileName = "audit.log"
}

public enum APTerminalStoragePaths {
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        appName: String = APTerminalConfiguration.appName
    ) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent(appName, isDirectory: true)
    }

    public static func hostSettingsFileURL(
        fileManager: FileManager = .default,
        appName: String = APTerminalConfiguration.appName
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, appName: appName)
            .appendingPathComponent(APTerminalConfiguration.hostSettingsFileName, isDirectory: false)
    }

    public static func trustedHostsFileURL(
        fileManager: FileManager = .default,
        appName: String = APTerminalConfiguration.appName
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, appName: appName)
            .appendingPathComponent(APTerminalConfiguration.trustedHostsFileName, isDirectory: false)
    }

    public static func auditLogFileURL(
        fileManager: FileManager = .default,
        appName: String = APTerminalConfiguration.appName
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, appName: appName)
            .appendingPathComponent(APTerminalConfiguration.auditLogFileName, isDirectory: false)
    }
}

public enum APTerminalAppMetadata {
    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        if let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           value.isEmpty == false {
            return value
        }

        if let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           value.isEmpty == false {
            return value
        }

        return APTerminalConfiguration.defaultAppVersion
    }
}
