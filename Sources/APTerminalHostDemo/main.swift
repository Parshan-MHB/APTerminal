import Foundation
import APTerminalCore
import APTerminalHost
import APTerminalProtocol
import APTerminalSecurity

@main
struct APTerminalHostDemoApp {
    static func main() async {
        let hostName = Host.current().localizedName ?? "Mac"
        let hostSettingsStore = FileHostSettingsStore(fileURL: FileHostSettingsStore.defaultFileURL())
        let existingSettings = (try? hostSettingsStore.loadSettings()) ?? HostSettings()
        let hostDeviceID = existingSettings.hostDeviceID ?? .random()
        if existingSettings.hostDeviceID == nil {
            var updatedSettings = existingSettings
            updatedSettings.hostDeviceID = hostDeviceID
            try? hostSettingsStore.saveSettings(updatedSettings)
        }
        let signingPrivateKey = try! InMemorySigningKeyStore().loadOrCreatePrivateKey()
        let runtime = HostRuntime(
            hostIdentity: DeviceIdentity(
                id: hostDeviceID,
                name: hostName,
                platform: .macOS,
                appVersion: APTerminalAppMetadata.currentAppVersion()
            ),
            sessionManager: SessionManager(),
            trustRegistry: TrustedDeviceRegistry(store: InMemoryTrustedDeviceStore()),
            pairingService: PairingService(),
            auditLogger: AuditLogger(logURL: AuditLogger.defaultLogURL()),
            signingPrivateKey: signingPrivateKey,
            externalSessionProvider: ExternalTerminalSessionProvider(
                configuration: .init(
                    maximumChunkBytes: existingSettings.externalPreview.chunkBytes,
                    maximumSnapshotBytes: existingSettings.externalPreview.snapshotBytes,
                    maximumSnapshotLines: existingSettings.externalPreview.snapshotLines,
                    refreshIntervalMilliseconds: existingSettings.externalPreview.refreshIntervalMilliseconds
                )
            ),
            configuration: .init(
                connectionMode: existingSettings.connectionMode,
                bootstrapEndpointKind: LocalNetworkAddressResolver.preferredAddress(
                    for: existingSettings.connectionMode,
                    explicitInternetHost: existingSettings.explicitInternetHost
                )?.kind ?? .fallback,
                allowExternalTerminalPreviews: existingSettings.allowExternalTerminalPreviews,
                pairingTokenLifetimeSeconds: existingSettings.resolvedPairingTokenLifetimeSeconds,
                singleUseBootstrapPayloads: existingSettings.singleUseBootstrapPayloads,
                sessionLaunchProfiles: existingSettings.sessionLaunchProfiles,
                allowedWorkingDirectories: existingSettings.allowedWorkingDirectories
            )
        )

        do {
            let server = try HostServer(
                runtime: runtime,
                port: existingSettings.hostPort,
                advertiseBonjour: existingSettings.connectionMode == .lan,
                connectionConfiguration: .init(
                    heartbeatInterval: existingSettings.transport.heartbeatIntervalSeconds,
                    idleTimeout: existingSettings.transport.idleTimeoutSeconds,
                    maximumPendingTerminalBytes: existingSettings.transport.maximumPendingTerminalBytes,
                    maximumInboundFrameBytes: existingSettings.transport.maximumInboundFrameBytes,
                    maximumBufferedInboundBytes: existingSettings.transport.maximumBufferedInboundBytes
                )
            )
            server.start()

            let token = await runtime.createPairingToken()
            _ = try await runtime.createSession(
                CreateSessionRequest(
                    shellPath: nil,
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                    initialSize: SessionWindowSize(rows: 40, columns: 120)
                )
            )

            while server.port == nil {
                try await Task.sleep(for: .milliseconds(100))
            }

            let portDescription = server.port.map(String.init(describing:)) ?? "pending"
            print("APTerminal host demo running on port \(portDescription)")
            print("Pairing token: \(token.value)")
            let bootstrap = PairingBootstrapPayload(
                hostIdentity: runtime.hostIdentity,
                host: LocalNetworkAddressResolver.preferredAddress(
                    for: existingSettings.connectionMode,
                    explicitInternetHost: existingSettings.explicitInternetHost
                )?.address ?? "127.0.0.1",
                port: server.port?.rawValue ?? 0,
                connectionMode: existingSettings.connectionMode,
                endpointKind: LocalNetworkAddressResolver.preferredAddress(
                    for: existingSettings.connectionMode,
                    explicitInternetHost: existingSettings.explicitInternetHost
                )?.kind ?? .fallback,
                token: token,
                hostPublicKey: runtime.hostSigningPublicKey
            )
            if let bootstrapJSON = try? bootstrap.encodedJSONString() {
                print("Bootstrap payload: \(bootstrapJSON)")
            }
            print("Press Ctrl+C to stop.")

            while true {
                try await Task.sleep(for: .seconds(60))
            }
        } catch {
            fputs("Host demo failed: \(error)\n", stderr)
        }
    }
}
