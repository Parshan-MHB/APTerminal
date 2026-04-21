import AppKit
import Foundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Network
import APTerminalCore
import APTerminalHost
import APTerminalProtocol
import APTerminalSecurity

@MainActor
final class MacCompanionAppModel: ObservableObject {
    private enum HostStartupError: Error, LocalizedError {
        case listenerFailed(NWError)
        case listenerCancelled
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .listenerFailed(error):
                return "Listener failed to start: \(error)"
            case .listenerCancelled:
                return "Listener cancelled before startup completed"
            case .timedOut:
                return "Listener did not become ready before startup timed out"
            }
        }
    }

    struct LegacyDemoHostProcess: Identifiable, Equatable {
        let pid: Int32
        let command: String

        var id: Int32 { pid }
    }

    @Published var trustedDevices: [TrustedDeviceRecord] = []
    @Published var sessions: [SessionSummary] = []
    @Published var localNetworkAddresses: [LocalNetworkAddress] = []
    @Published var auditEvents: [AuditEventRecord] = []
    @Published var pairingPayloadJSONString: String = ""
    @Published var pairingQRCodeImage: NSImage?
    @Published var pairingTokenExpiresAt: Date?
    @Published var statusMessage: String = ""
    @Published var isHostRunning = false
    @Published var hostPort: UInt16?
    @Published var connectionMode: HostConnectionMode = .lan
    @Published var explicitInternetHost: String = ""
    @Published var allowExternalTerminalPreviews = true
    @Published var allowManagedSessionContentPreviews = true
    @Published var selectedBootstrapEndpoint: LocalNetworkAddress?
    @Published var exposureWarnings: [String] = []
    @Published var exposureBlockingIssues: [String] = []
    @Published var legacyDemoHostProcesses: [LegacyDemoHostProcess] = []
    @Published var closingSessionIDs: Set<SessionID> = []

    private var server: HostServer?
    private var runtime: HostRuntime?
    private var sessionManager: SessionManager?
    private var externalSessionProvider: ExternalTerminalSessionProvider?
    private var trustRegistry: TrustedDeviceRegistry?
    private var hostIdentity: DeviceIdentity?
    private var signingPrivateKey: Curve25519.Signing.PrivateKey?
    private var pairingService: PairingService?
    private var hostSettings = HostSettings()
    private var auditLogURL = AuditLogger.defaultLogURL()
    private var autoRefreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private let logger = StructuredLogger(subsystem: "com.apterminal", category: "MacCompanionAppModel")
    private let hostSettingsStore = FileHostSettingsStore(fileURL: FileHostSettingsStore.defaultFileURL())
    private let qrFilter = CIFilter.qrCodeGenerator()
    private let ciContext = CIContext()

    func boot() async {
        if runtime == nil {
            await initializeRuntimeIfNeeded()
        }

        startAutoRefreshLoopIfNeeded()
        await refreshLegacyDemoHostProcesses()
        await startHost()
        await refresh()
    }

    func startHost() async {
        guard server == nil, let runtime else { return }

        let settings = hostSettings
        let maxBindAttempts = APTerminalConfiguration.defaultHostStartupBindRetryCount

        for attempt in 0..<maxBindAttempts {
            do {
                refreshLocalNetworkAddresses()
                let exposureEvaluation = refreshExposureState(for: settings)
                let candidateAddresses = localNetworkAddresses.isEmpty
                    ? LocalNetworkAddressResolver.candidateAddresses()
                    : localNetworkAddresses
                guard exposureEvaluation.canStart,
                      let bindEndpoint = LocalNetworkAddressResolver.listenerBindAddress(
                        for: settings.connectionMode,
                        explicitInternetHost: settings.explicitInternetHost,
                        candidateAddresses: candidateAddresses
                      ) else {
                    pairingPayloadJSONString = ""
                    pairingQRCodeImage = nil
                    statusMessage = exposureEvaluation.blockingIssues.map(\.summary).joined(separator: " ")
                    try? await AuditLogger(logURL: auditLogURL).log(
                        .init(
                            kind: .connectionDenied,
                            note: "Host startup blocked: \(statusMessage)"
                        )
                    )
                    isHostRunning = false
                    return
                }

                let server = try HostServer(
                    runtime: runtime,
                    port: settings.hostPort,
                    bindHost: bindEndpoint.address,
                    advertiseBonjour: settings.connectionMode == .lan,
                    connectionConfiguration: .init(
                        heartbeatInterval: settings.transport.heartbeatIntervalSeconds,
                        idleTimeout: settings.transport.idleTimeoutSeconds,
                        maximumPendingTerminalBytes: settings.transport.maximumPendingTerminalBytes,
                        maximumInboundFrameBytes: settings.transport.maximumInboundFrameBytes,
                        maximumBufferedInboundBytes: settings.transport.maximumBufferedInboundBytes
                    )
                )
                server.start()
                self.server = server

                try await waitForHostReady(server)

                hostPort = server.port?.rawValue
                isHostRunning = true
                refreshLocalNetworkAddresses()
                await regeneratePairingPayload()
                statusMessage = "Host running on port \(hostPort.map(String.init) ?? "pending")"
                return
            } catch {
                let shouldRetry = isTransientAddressInUse(error) && attempt < (maxBindAttempts - 1)
                self.server?.stop()
                self.server = nil
                hostPort = nil

                if shouldRetry {
                    try? await Task.sleep(
                        for: .milliseconds(APTerminalConfiguration.defaultHostStartupBindRetryDelayMilliseconds)
                    )
                    continue
                }

                logger.error("Failed to start host runtime", metadata: ["error": String(describing: error)])
                pairingPayloadJSONString = ""
                pairingQRCodeImage = nil
                statusMessage = "Failed to start host: \(error)"
                isHostRunning = false
                return
            }
        }
    }

    private func waitForHostReady(_ server: HostServer) async throws {
        let deadline = Date().addingTimeInterval(APTerminalConfiguration.defaultHostStartupTimeoutSeconds)
        while server.port == nil {
            switch server.listenerState {
            case let .failed(error):
                throw HostStartupError.listenerFailed(error)
            case .cancelled:
                throw HostStartupError.listenerCancelled
            default:
                break
            }

            guard Date() < deadline else {
                throw HostStartupError.timedOut
            }

            try await Task.sleep(
                for: .milliseconds(APTerminalConfiguration.defaultHostStartupPollIntervalMilliseconds)
            )
        }
    }

    private func waitForHostStopped(_ server: HostServer) async {
        let deadline = Date().addingTimeInterval(APTerminalConfiguration.defaultHostStopTimeoutSeconds)
        while Date() < deadline {
            switch server.listenerState {
            case .cancelled, .failed:
                return
            default:
                break
            }

            try? await Task.sleep(
                for: .milliseconds(APTerminalConfiguration.defaultHostStopPollIntervalMilliseconds)
            )
        }
    }

    private func isTransientAddressInUse(_ error: Error) -> Bool {
        if let startupError = error as? HostStartupError,
           case let .listenerFailed(networkError) = startupError,
           case let .posix(code) = networkError {
            return code == .EADDRINUSE
        }

        if let networkError = error as? NWError,
           case let .posix(code) = networkError {
            return code == .EADDRINUSE
        }

        return false
    }

    func stopHost(closeManagedSessions: Bool = true) async {
        if closeManagedSessions {
            await sessionManager?.closeAllSessions()
        }
        let activeServer = server
        activeServer?.stop()
        if let activeServer {
            await waitForHostStopped(activeServer)
        }
        server = nil
        hostPort = nil
        isHostRunning = false
        closingSessionIDs.removeAll()
        pairingPayloadJSONString = ""
        pairingQRCodeImage = nil
        sessions = await loadVisibleSessions()
        statusMessage = "Host stopped"
    }

    func toggleHost() async {
        if isHostRunning {
            await stopHost()
        } else {
            await startHost()
        }
    }

    func closeSession(_ sessionID: SessionID) async {
        guard let sessionManager else { return }
        guard closingSessionIDs.contains(sessionID) == false else { return }

        closingSessionIDs.insert(sessionID)
        defer { closingSessionIDs.remove(sessionID) }

        do {
            try await sessionManager.closeSession(id: sessionID)
            sessions.removeAll { $0.id == sessionID }
            statusMessage = "Closed session"
            Task {
                await refresh()
            }
        } catch {
            logger.error("Failed to close session", metadata: ["error": String(describing: error)])
            statusMessage = "Failed to close session: \(error)"
            await refresh()
        }
    }

    func refresh() async {
        guard let runtime else { return }
        guard isRefreshing == false else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        trustedDevices = await runtime.trustedDevices()
        await syncExternalPreviewProviderToPolicy()
        sessions = await loadVisibleSessions()
        refreshLocalNetworkAddresses()
        await refreshLegacyDemoHostProcesses()
    }

    func stopLegacyDemoHosts() {
        let processes = legacyDemoHostProcesses
        guard processes.isEmpty == false else {
            statusMessage = "No legacy demo hosts running"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = processes.map { String($0.pid) }

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                Task {
                    await refreshLegacyDemoHostProcesses()
                }
                statusMessage = "Stopped \(processes.count) legacy demo host\(processes.count == 1 ? "" : "s")"
            } else {
                statusMessage = "Failed to stop legacy demo hosts"
            }
        } catch {
            logger.error("Failed to stop legacy demo hosts", metadata: ["error": String(describing: error)])
            statusMessage = "Failed to stop legacy demo hosts: \(error)"
        }
    }

    private func initializeRuntimeIfNeeded() async {
        guard runtime == nil else { return }
        logger.info("Booting Mac companion app model")

        var existingSettings = (try? hostSettingsStore.loadSettings()) ?? HostSettings()
        let hostDeviceID = existingSettings.hostDeviceID ?? .random()
        if existingSettings.hostDeviceID == nil {
            existingSettings.hostDeviceID = hostDeviceID
        }
        try? hostSettingsStore.saveSettings(existingSettings)

        hostIdentity = hostIdentity ?? DeviceIdentity(
            id: hostDeviceID,
            name: Host.current().localizedName ?? "Mac",
            platform: .macOS,
            appVersion: APTerminalAppMetadata.currentAppVersion()
        )
        signingPrivateKey = signingPrivateKey ?? (try! KeychainSigningKeyStore().loadOrCreatePrivateKey())
        pairingService = pairingService ?? PairingService()
        trustRegistry = trustRegistry ?? TrustedDeviceRegistry(store: KeychainTrustedDeviceStore())
        sessionManager = sessionManager ?? SessionManager()
        auditLogURL = AuditLogger.defaultLogURL()

        hostSettings = existingSettings
        await rebuildRuntime(for: existingSettings, preserveManagedSessions: true)
        refreshLocalNetworkAddresses()
        _ = refreshExposureState(for: existingSettings)
    }

    private func rebuildRuntime(for settings: HostSettings, preserveManagedSessions: Bool) async {
        if preserveManagedSessions == false {
            sessionManager = SessionManager()
        }

        guard
            let hostIdentity,
            let signingPrivateKey,
            let trustRegistry,
            let sessionManager,
            let pairingService
        else {
            return
        }

        let externalSessionProvider = await makeExternalSessionProvider(for: settings)
        let runtime = HostRuntime(
            hostIdentity: hostIdentity,
            sessionManager: sessionManager,
            trustRegistry: trustRegistry,
            pairingService: pairingService,
            auditLogger: AuditLogger(store: FileAuditEventStore(fileURL: auditLogURL)),
            signingPrivateKey: signingPrivateKey,
            externalSessionProvider: externalSessionProvider,
            configuration: runtimeConfiguration(for: settings)
        )

        self.runtime = runtime
        self.externalSessionProvider = externalSessionProvider
        self.hostSettings = settings
        self.connectionMode = settings.connectionMode
        self.explicitInternetHost = settings.explicitInternetHost ?? ""
        self.allowExternalTerminalPreviews = settings.allowExternalTerminalPreviews
        self.allowManagedSessionContentPreviews = settings.allowManagedSessionContentPreviews
        self.hostPort = settings.hostPort
    }

    private func makeExternalSessionProvider(for settings: HostSettings) async -> ExternalTerminalSessionProvider? {
        guard await shouldActivateExternalSessionProvider(for: settings) else {
            return nil
        }

        return ExternalTerminalSessionProvider(
            configuration: .init(
                maximumChunkBytes: settings.externalPreview.chunkBytes,
                maximumSnapshotBytes: settings.externalPreview.snapshotBytes,
                maximumSnapshotLines: settings.externalPreview.snapshotLines,
                refreshIntervalMilliseconds: settings.externalPreview.refreshIntervalMilliseconds
            )
        )
    }

    private func shouldActivateExternalSessionProvider(for settings: HostSettings) async -> Bool {
        settings.allowExternalTerminalPreviews
    }

    private func syncExternalPreviewProviderToPolicy() async {
        guard let runtime else { return }

        let provider = await makeExternalSessionProvider(for: hostSettings)
        await runtime.updatePreviewConfiguration(
            allowExternalTerminalPreviews: hostSettings.allowExternalTerminalPreviews,
            allowManagedSessionContentPreviews: hostSettings.allowManagedSessionContentPreviews,
            externalSessionProvider: provider
        )
        self.externalSessionProvider = provider
    }

    private func startAutoRefreshLoopIfNeeded() {
        guard autoRefreshTask == nil else { return }

        autoRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(APTerminalConfiguration.defaultHostRefreshIntervalSeconds))
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func regeneratePairingPayload() async {
        guard let runtime, let server else { return }

        while server.port == nil {
            try? await Task.sleep(
                for: .milliseconds(APTerminalConfiguration.defaultHostStartupPollIntervalMilliseconds)
            )
        }

        let token = await runtime.createPairingToken()
        pairingTokenExpiresAt = token.expiresAt

        guard let port = server.port?.rawValue else {
            pairingPayloadJSONString = "Host port unavailable"
            return
        }

        let selectedEndpoint = refreshExposureState(for: hostSettings).approvedEndpoint
        self.selectedBootstrapEndpoint = selectedEndpoint
        guard let selectedEndpoint else {
            pairingPayloadJSONString = ""
            pairingQRCodeImage = nil
            statusMessage = "No approved host endpoint is available for the selected connection mode."
            return
        }
        let hostAddress = selectedEndpoint.address

        let bootstrap = PairingBootstrapPayload(
            hostIdentity: runtime.hostIdentity,
            host: hostAddress,
            port: port,
            connectionMode: hostSettings.connectionMode,
            endpointKind: selectedEndpoint.kind,
            token: token,
            hostPublicKey: runtime.hostSigningPublicKey
        )
        pairingPayloadJSONString = (try? bootstrap.encodedJSONString()) ?? ""
        pairingQRCodeImage = makeQRCodeImage(from: pairingPayloadJSONString)

        statusMessage = "Pairing payload refreshed for \(hostAddress):\(port)"
        logger.info(
            "Regenerated pairing payload",
            metadata: [
                "hostAddress": hostAddress,
                "port": "\(port)",
            ]
        )
    }

    func createSession() async {
        guard let sessionManager else { return }

        do {
            _ = try await sessionManager.createSession(
                shellPath: nil,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                initialSize: SessionWindowSize(rows: 40, columns: 120)
            )
            sessions = await loadVisibleSessions()
            statusMessage = "Created session"
        } catch {
            logger.error("Failed to create session", metadata: ["error": String(describing: error)])
            statusMessage = "Failed to create session: \(error)"
        }
    }

    func revokeDevice(_ deviceID: DeviceID) async {
        guard let runtime else { return }

        do {
            try await runtime.revoke(deviceID: deviceID)
            statusMessage = "Revoked device"
            await refresh()
        } catch {
            logger.error(
                "Failed to revoke trusted device",
                metadata: [
                    "deviceID": deviceID.rawValue,
                    "error": String(describing: error),
                ]
            )
            statusMessage = "Failed to revoke device: \(error)"
        }
    }

    func setPreviewAccess(
        _ enabled: Bool,
        for deviceID: DeviceID,
        in mode: HostConnectionMode
    ) async {
        guard let runtime else { return }

        do {
            guard let existingRecord = await runtime.trustedDeviceRecord(for: deviceID) else {
                statusMessage = "Trusted device record no longer exists"
                return
            }

            var previewAccessModes = existingRecord.previewAccessModes
            if enabled {
                previewAccessModes.insert(mode)
            } else {
                previewAccessModes.remove(mode)
            }

            guard let updatedRecord = try await runtime.setPreviewAccessModes(previewAccessModes, for: deviceID) else {
                statusMessage = "Trusted device record no longer exists"
                return
            }

            statusMessage = enabled
                ? "Granted preview access to \(updatedRecord.identity.name) for \(mode.displayName)"
                : "Revoked preview access from \(updatedRecord.identity.name) for \(mode.displayName)"

            if enabled == false {
                server?.disconnectAuthenticatedDevice(deviceID)
            }

            await syncExternalPreviewProviderToPolicy()
            await refresh()
        } catch {
            logger.error(
                "Failed to update preview access",
                metadata: [
                    "deviceID": deviceID.rawValue,
                    "mode": mode.rawValue,
                    "error": String(describing: error),
                ]
            )
            statusMessage = "Failed to update preview access: \(error)"
        }
    }

    private func refreshLocalNetworkAddresses() {
        localNetworkAddresses = LocalNetworkAddressResolver.candidateAddresses()
        _ = refreshExposureState(for: hostSettings)
    }

    private func selectedBootstrapEndpoint(for settings: HostSettings) -> LocalNetworkAddress? {
        let candidateAddresses = localNetworkAddresses.isEmpty
            ? LocalNetworkAddressResolver.candidateAddresses()
            : localNetworkAddresses
        return LocalNetworkAddressResolver.exposureEvaluation(
            for: settings.connectionMode,
            explicitInternetHost: settings.explicitInternetHost,
            candidateAddresses: candidateAddresses
        ).approvedEndpoint
    }

    private func runtimeConfiguration(for settings: HostSettings) -> HostRuntimeConfiguration {
        HostRuntimeConfiguration(
            connectionMode: settings.connectionMode,
            bootstrapEndpointKind: selectedBootstrapEndpoint(for: settings)?.kind ?? .fallback,
            allowExternalTerminalPreviews: settings.allowExternalTerminalPreviews,
            allowManagedSessionContentPreviews: settings.allowManagedSessionContentPreviews,
            pairingTokenLifetimeSeconds: settings.resolvedPairingTokenLifetimeSeconds,
            singleUseBootstrapPayloads: settings.singleUseBootstrapPayloads,
            sessionLaunchProfiles: settings.sessionLaunchProfiles,
            allowedWorkingDirectories: settings.allowedWorkingDirectories
        )
    }

    func setConnectionMode(_ mode: HostConnectionMode) async {
        guard hostSettings.connectionMode != mode else { return }

        await updateHostSettings(
            description: "Connection mode updated to \(mode.displayName)"
        ) { settings in
            // Connection-mode changes already require a fresh pairing payload, so
            // rebinding on a fresh ephemeral port avoids stale listener conflicts.
            settings.hostPort = 0
            settings.connectionMode = mode
            settings.allowExternalTerminalPreviews = (mode == .lan)
        }
    }

    func setExplicitInternetHost(_ host: String) async {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedValue = normalizedHost.isEmpty ? nil : normalizedHost
        guard hostSettings.explicitInternetHost != storedValue else { return }

        await updateHostSettings(description: "Internet endpoint updated") { settings in
            settings.explicitInternetHost = storedValue
        }
    }

    func setExternalTerminalPreviewsEnabled(_ enabled: Bool) async {
        guard hostSettings.allowExternalTerminalPreviews != enabled else { return }

        await updatePreviewSettings(
            description: enabled
                ? "Remote external previews enabled"
                : "Remote external previews disabled",
            auditEventKind: enabled ? .externalPreviewsEnabled : .externalPreviewsDisabled
        ) { settings in
            settings.allowExternalTerminalPreviews = enabled
        }
    }

    func setManagedSessionContentPreviewsEnabled(_ enabled: Bool) async {
        guard hostSettings.allowManagedSessionContentPreviews != enabled else { return }

        await updatePreviewSettings(
            description: enabled
                ? "Managed session content previews enabled"
                : "Managed session content previews disabled"
        ) { settings in
            settings.allowManagedSessionContentPreviews = enabled
        }
    }

    private func updatePreviewSettings(
        description: String,
        auditEventKind: AuditEventKind? = nil,
        mutate: (inout HostSettings) -> Void
    ) async {
        mutate(&hostSettings)
        _ = refreshExposureState(for: hostSettings)
        try? hostSettingsStore.saveSettings(hostSettings)

        if let auditEventKind {
            try? await AuditLogger(logURL: auditLogURL).log(.init(kind: auditEventKind))
        }
        self.allowExternalTerminalPreviews = hostSettings.allowExternalTerminalPreviews
        self.allowManagedSessionContentPreviews = hostSettings.allowManagedSessionContentPreviews
        await syncExternalPreviewProviderToPolicy()

        if hostSettings.allowExternalTerminalPreviews == false {
            server?.disconnectAllPeers()
        }

        statusMessage = description
        await refresh()
    }

    private func updateHostSettings(
        description: String,
        auditEventKind: AuditEventKind? = nil,
        mutate: (inout HostSettings) -> Void
    ) async {
        let previousSettings = hostSettings
        var prospectiveSettings = hostSettings
        mutate(&prospectiveSettings)

        let wasRunning = isHostRunning
        let prospectiveExposureEvaluation = exposureEvaluation(for: prospectiveSettings)
        if wasRunning, prospectiveExposureEvaluation.canStart == false {
            refreshExposureState(for: previousSettings)
            statusMessage = prospectiveExposureEvaluation.blockingIssues.map(\.summary).joined(separator: " ")
            try? await AuditLogger(logURL: auditLogURL).log(
                .init(
                    kind: .connectionDenied,
                    note: "Host configuration change blocked: \(statusMessage)"
                )
            )
            return
        }

        if wasRunning {
            await stopHost(closeManagedSessions: false)
        }

        hostSettings = prospectiveSettings
        _ = refreshExposureState(for: hostSettings)
        try? hostSettingsStore.saveSettings(hostSettings)

        if let auditEventKind {
            try? await AuditLogger(logURL: auditLogURL).log(.init(kind: auditEventKind))
        }

        await rebuildRuntime(for: hostSettings, preserveManagedSessions: true)

        if wasRunning {
            await startHost()
            guard isHostRunning else {
                hostSettings = previousSettings
                _ = refreshExposureState(for: hostSettings)
                try? hostSettingsStore.saveSettings(hostSettings)
                await rebuildRuntime(for: hostSettings, preserveManagedSessions: true)
                await startHost()

                if isHostRunning {
                    statusMessage = "Failed to apply new host settings. Restored previous configuration."
                }
                await refresh()
                return
            }
        }

        statusMessage = description
        await refresh()
    }

    private func loadVisibleSessions() async -> [SessionSummary] {
        let managedSessions = await sessionManager?.listSessions() ?? []
        let externalSessions = await loadExternalSessionsWithTimeout()
        return (managedSessions + externalSessions)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func loadExternalSessionsWithTimeout() async -> [SessionSummary] {
        guard let externalSessionProvider else {
            return []
        }

        return await withTaskGroup(of: [SessionSummary].self) { group in
            group.addTask {
                await externalSessionProvider.listSessions()
            }

            group.addTask {
                try? await Task.sleep(
                    for: .milliseconds(APTerminalConfiguration.defaultExternalPreviewLoadTimeoutMilliseconds)
                )
                return []
            }

            let sessions = await group.next() ?? []
            group.cancelAll()
            return sessions
        }
    }

    func refreshAuditEvents() async {
        do {
            let logger = AuditLogger(logURL: auditLogURL)
            auditEvents = try await logger.recentEvents(limit: hostSettings.displayedAuditEventLimit)
                .sorted { $0.occurredAt > $1.occurredAt }
        } catch {
            self.logger.error("Failed to read audit log", metadata: ["error": String(describing: error)])
            statusMessage = "Failed to read audit log: \(error)"
        }
    }

    func copyAuditLogPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(auditLogURL.path, forType: .string)
        statusMessage = "Copied audit log path"
    }

    var auditLogPath: String {
        auditLogURL.path
    }

    var hostStatusSummary: String {
        if isHostRunning {
            if let hostPort {
                return "Running on port \(hostPort)"
            }
            return "Running"
        }

        return "Stopped"
    }

    var hasLegacyDemoHostWarning: Bool {
        legacyDemoHostProcesses.isEmpty == false
    }

    var legacyDemoHostWarningSummary: String {
        let count = legacyDemoHostProcesses.count
        guard count > 0 else {
            return "No legacy demo hosts detected"
        }

        return "\(count) legacy demo host\(count == 1 ? "" : "s") detected"
    }

    var selectedBootstrapEndpointSummary: String {
        guard let selectedBootstrapEndpoint else {
            return "Unavailable"
        }

        return "\(selectedBootstrapEndpoint.address) (\(selectedBootstrapEndpoint.kind.displayName))"
    }

    var trustedDeviceStatusSummary: String {
        let count = trustedDevices.count
        return "\(count) trusted device\(count == 1 ? "" : "s")"
    }

    var previewPrivilegeSummary: String {
        let previewEnabledCount = trustedDevices.filter {
            $0.previewAccessModes.contains(connectionMode)
        }.count

        if allowExternalTerminalPreviews == false && allowManagedSessionContentPreviews == false {
            return "Preview content disabled"
        }

        if previewEnabledCount == 0 {
            return "No device has \(connectionMode.displayName.lowercased()) preview access"
        }

        return "\(previewEnabledCount) device\(previewEnabledCount == 1 ? "" : "s") can access \(connectionMode.displayName.lowercased()) previews"
    }

    var previewSubsystemStatusSummary: String {
        if allowExternalTerminalPreviews == false {
            return "External previews inactive"
        }

        return externalSessionProvider == nil ? "External previews unavailable" : "External previews active"
    }

    func previewAccessEnabled(for device: TrustedDeviceRecord, mode: HostConnectionMode) -> Bool {
        device.previewAccessModes.contains(mode)
    }

    func previewAccessSummary(for device: TrustedDeviceRecord) -> String {
        let modes = HostConnectionMode.allCases.filter { device.previewAccessModes.contains($0) }
        guard modes.isEmpty == false else {
            return "Base access only"
        }

        if modes.count == HostConnectionMode.allCases.count {
            return "Preview access on all modes"
        }

        return "Preview access on " + modes.map(\.displayName).joined(separator: ", ")
    }

    var exposureBlockingSummary: String? {
        exposureBlockingIssues.isEmpty ? nil : exposureBlockingIssues.joined(separator: " ")
    }

    var exposureWarningSummary: String? {
        exposureWarnings.isEmpty ? nil : exposureWarnings.joined(separator: " ")
    }

    @discardableResult
    private func refreshExposureState(for settings: HostSettings) -> HostExposureEvaluation {
        let evaluation = exposureEvaluation(for: settings)
        selectedBootstrapEndpoint = evaluation.approvedEndpoint
        exposureWarnings = evaluation.warnings.map(\.summary)
        exposureBlockingIssues = evaluation.blockingIssues.map(\.summary)
        return evaluation
    }

    private func exposureEvaluation(for settings: HostSettings) -> HostExposureEvaluation {
        let candidateAddresses = localNetworkAddresses.isEmpty
            ? LocalNetworkAddressResolver.candidateAddresses()
            : localNetworkAddresses
        return LocalNetworkAddressResolver.exposureEvaluation(
            for: settings.connectionMode,
            explicitInternetHost: settings.explicitInternetHost,
            candidateAddresses: candidateAddresses
        )
    }

    private func makeQRCodeImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8), string.isEmpty == false else {
            return nil
        }

        qrFilter.setValue(data, forKey: "inputMessage")
        qrFilter.correctionLevel = "H"

        guard let outputImage = qrFilter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let qrImage = NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
        let paddedSize = NSSize(width: scaledImage.extent.width + 48, height: scaledImage.extent.height + 48)
        let image = NSImage(size: paddedSize)

        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: paddedSize)).fill()
        qrImage.draw(
            in: NSRect(x: 24, y: 24, width: scaledImage.extent.width, height: scaledImage.extent.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        image.unlockFocus()

        return image
    }

    private func refreshLegacyDemoHostProcesses() async {
        legacyDemoHostProcesses = await Self.detectLegacyDemoHostProcesses()
    }

    private static func detectLegacyDemoHostProcesses() async -> [LegacyDemoHostProcess] {
        await Task.detached(priority: .utility) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "apterminal-host-demo"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            if process.terminationStatus == 0 {
                return output
                    .split(separator: "\n")
                    .compactMap(Self.parseLegacyDemoHostProcess(from:))
                    .sorted { $0.pid < $1.pid }
            } else {
                return []
            }
        } catch {
            return []
        }
        }.value
    }

    nonisolated private static func parseLegacyDemoHostProcess(from line: Substring) -> LegacyDemoHostProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]) else {
            return nil
        }

        return LegacyDemoHostProcess(pid: pid, command: String(parts[1]))
    }
}
