import CryptoKit
import Foundation
import UIKit
import APTerminalClient
import APTerminalProtocol
import APTerminalSecurity

struct PasteProtectionPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct SensitiveActionPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmButtonTitle: String
    let isDestructive: Bool
}

struct InputDeliveryDiagnostics {
    var successfulEventCount: Int = 0
    var failedEventCount: Int = 0
    var lastSendLatencyMilliseconds: Int?
    var lastFailureSummary: String?

    var summaryText: String {
        let latencyText = lastSendLatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
        return "Input \(successfulEventCount) sent • \(failedEventCount) failed • last \(latencyText)"
    }
}

struct HostConnectionDetails: Equatable {
    var host: DeviceIdentity
    var hostAddress: String
    var port: UInt16
    var connectionMode: HostConnectionMode
    var endpointKind: HostEndpointKind
    var previewAccessModes: [HostConnectionMode]
    var trustExpiresAt: Date?
}

enum TerminalTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .paper:
            return "Paper"
        case .night:
            return "Night"
        }
    }
}

enum LocalNetworkAccessState: Equatable {
    case unknown
    case requesting
    case granted
    case denied(String)

    var title: String {
        switch self {
        case .unknown:
            return "Permission Needed"
        case .requesting:
            return "Requesting Access"
        case .granted:
            return "Access Granted"
        case .denied:
            return "Access Blocked"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "Allow Local Network access so the app can find your Mac and connect to it on Wi-Fi."
        case .requesting:
            return "Watch for the iOS Local Network prompt and tap Allow."
        case .granted:
            return "The app can browse and connect to Macs on your local network."
        case let .denied(message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .unknown:
            return "wifi.exclamationmark"
        case .requesting:
            return "dot.radiowaves.left.and.right"
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.octagon.fill"
        }
    }
}

@MainActor
final class iOSClientAppModel: ObservableObject {
    private static let viewOnlyModeDefaultsKey = "security.viewOnlyModeEnabled"
    private static let stableHostPort: UInt16 = APTerminalConfiguration.defaultHostPort

    @Published var trustedHosts: [TrustedHostRecord] = []
    @Published var sessions: [SessionSummary] = []
    @Published var terminalText: String = ""
    @Published var connectionStatusText: String = "Disconnected"
    @Published var currentConnectionDetails: HostConnectionDetails?
    @Published var bootstrapJSONString: String = ""
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var isQRScannerPresented = false
    @Published var pasteProtectionEnabled = true
    @Published var warnOnEscapeSequences = true
    @Published var pendingPasteProtectionPrompt: PasteProtectionPrompt?
    @Published var pendingSensitiveActionPrompt: SensitiveActionPrompt?
    @Published var pendingInput: String = ""
    @Published var inputDiagnostics = InputDeliveryDiagnostics()
    @Published var selectedSessionID: SessionID?
    @Published var renameTarget: SessionSummary?
    @Published var renameDraft: String = ""
    @Published var terminalTheme: TerminalTheme = .system
    @Published var viewOnlyModeEnabled: Bool
    @Published private(set) var localNetworkAccessState: LocalNetworkAccessState = .unknown

    private let buffer = TerminalBufferStore()
    private let localNetworkAuthorizer = LocalNetworkAuthorizer()
    private let trustedHostRegistry = TrustedHostRegistry(store: FileTrustedHostStore(fileURL: FileTrustedHostStore.defaultFileURL()))
    private let userDefaults: UserDefaults
    private let clientIdentity: PersistentClientIdentity
    private var pendingProtectedAction: ProtectedTerminalAction?
    private var pendingSensitiveAction: SensitiveAction?
    private var reportedViewportSizes: [SessionID: SessionWindowSize] = [:]
    private var managedSessionTranscriptCache: [SessionID: String] = [:]
    private var managedSessionTranscriptCarryover: [SessionID: String] = [:]
    private var preferredSessionIDForReconnect: SessionID?
    private var lastConnectedHostID: DeviceID?
    private var shouldRestoreConnection = false
    private var explicitDisconnectRequested = false
    private var reconnectTask: Task<Void, Never>?
    private lazy var connectionManager = ConnectionManager(
        deviceIdentity: clientIdentity.identity,
        privateKey: clientIdentity.privateKey,
        trustedHostRegistry: trustedHostRegistry
    )

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.clientIdentity = PersistentClientIdentity.load(userDefaults: userDefaults)
        self.viewOnlyModeEnabled = userDefaults.bool(forKey: Self.viewOnlyModeDefaultsKey)

        Task {
            await connectionManager.setTerminalOutputHandler { [weak self] chunk in
                guard let self else { return }
                Task {
                    await self.buffer.consume(chunk)
                    let snapshot = await self.buffer.snapshot()
                    let transcript = await self.buffer.transcriptText()
                    await MainActor.run {
                        if let selectedSessionID = self.selectedSessionID,
                           let session = self.session(for: selectedSessionID),
                           session.capabilities.supportsInput {
                            let combinedTranscript = self.combinedManagedTranscript(
                                for: selectedSessionID,
                                liveTranscript: transcript
                            )
                            self.terminalText = combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? snapshot.renderedText(showCursor: true)
                                : combinedTranscript
                            self.managedSessionTranscriptCache[selectedSessionID] = self.terminalText
                        } else {
                            self.terminalText = snapshot.renderedText(showCursor: true)
                        }
                    }
                }
            }

            await connectionManager.setConnectionStateHandler { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .disconnected:
                        self.connectionStatusText = "Disconnected"
                        self.selectedSessionID = nil
                        self.refreshConnectionDetails()
                        if self.explicitDisconnectRequested == false {
                            self.scheduleAutoReconnect(reason: "Connection lost")
                        }
                    case let .connecting(host, port):
                        self.connectionStatusText = "Connecting to \(host):\(port)"
                    case let .connected(host, hostAddress, port):
                        self.explicitDisconnectRequested = false
                        self.lastConnectedHostID = host.id
                        self.shouldRestoreConnection = true
                        self.connectionStatusText = "Connected to \(host.name) at \(hostAddress):\(port)"
                        self.currentConnectionDetails = HostConnectionDetails(
                            host: host,
                            hostAddress: hostAddress,
                            port: port,
                            connectionMode: self.currentConnectionDetails?.connectionMode ?? .lan,
                            endpointKind: self.currentConnectionDetails?.endpointKind ?? .localNetwork,
                            previewAccessModes: self.currentConnectionDetails?.previewAccessModes ?? [],
                            trustExpiresAt: self.currentConnectionDetails?.trustExpiresAt
                        )
                    }
                }
            }
        }
    }

    func startDiscovery() {
        Task {
            await reloadTrustedHosts()
        }
    }

    func requestLocalNetworkAccess(forceRetry: Bool = true) async {
        errorMessage = nil
        localNetworkAccessState = .requesting
        connectionStatusText = "Requesting local network access"

        do {
            _ = try await localNetworkAuthorizer.requestAccess(forceRetry: forceRetry)
            localNetworkAccessState = .granted
            connectionStatusText = isConnectedStatusText ? connectionStatusText : "Local network access granted"
            await reloadTrustedHosts()
        } catch {
            let message = userFacingMessage(for: error, fallback: "Local network access failed")
            localNetworkAccessState = .denied(message)
            connectionStatusText = "Local network access needed"
            errorMessage = message
        }
    }

    func sceneDidEnterBackground() {
        shouldRestoreConnection = shouldRestoreConnection || selectedSessionID != nil || sessions.isEmpty == false
    }

    func sceneDidBecomeActive() {
        if shouldRestoreConnection {
            scheduleAutoReconnect(reason: "Resuming session")
        }
    }

    func connectUsingBootstrapJSONString() async {
        busyMessage = "Pairing with Mac..."
        defer { busyMessage = nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        errorMessage = nil

        guard let data = bootstrapJSONString.data(using: .utf8) else {
            connectionStatusText = "Invalid bootstrap text"
            return
        }

        do {
            let bootstrap = try decoder.decode(PairingBootstrapPayload.self, from: data)
            try await ensureConnectivityAccessIfNeeded(
                connectionMode: bootstrap.connectionMode,
                endpointKind: bootstrap.endpointKind
            )
            try await connect(using: bootstrap)
        } catch {
            present(error: error, fallback: "Connect failed")
        }
    }

    func attachSession(_ sessionID: SessionID) async {
        busyMessage = "Attaching session..."
        defer { busyMessage = nil }

        do {
            try await performAttachSession(sessionID)
        } catch {
            if shouldRetryAttachAfterReconnect(error) {
                do {
                    try await reconnectForSessionOperation()
                    try await performAttachSession(sessionID)
                    return
                } catch {
                    if shouldReconcileAfterAttachFailure(error) {
                        reconcileAfterRecoverableSessionFailure(for: sessionID)
                    }
                    present(error: error, fallback: "Attach failed")
                    return
                }
            }

            if shouldReconcileAfterAttachFailure(error) {
                reconcileAfterRecoverableSessionFailure(for: sessionID)
            }
            present(error: error, fallback: "Attach failed")
        }
    }

    func refreshSessions() async {
        busyMessage = "Refreshing sessions..."
        defer { busyMessage = nil }

        do {
            sessions = try await connectionManager.listSessions()
            reconcileSelection(with: sessions)
            await reloadTrustedHosts()
        } catch {
            present(error: error, fallback: "Refresh failed")
        }
    }

    func connect(to trustedHost: TrustedHostRecord) async {
        busyMessage = "Connecting to \(trustedHost.host.name)..."
        defer { busyMessage = nil }

        do {
            try await ensureConnectivityAccessIfNeeded(for: trustedHost)
            explicitDisconnectRequested = false
            let hello = try await connectToTrustedHost(trustedHost)
            lastConnectedHostID = trustedHost.host.id
            shouldRestoreConnection = true
            updateConnectionDetails(
                host: hello.device,
                hostAddress: trustedHost.hostAddress,
                port: trustedHost.port,
                connectionMode: hello.connectionMode ?? trustedHost.connectionMode,
                endpointKind: hello.endpointKind ?? trustedHost.endpointKind,
                previewAccessModes: hello.previewAccessModes ?? [],
                trustExpiresAt: trustedHost.expiresAt
            )
            sessions = try await connectionManager.listSessions()
            reconcileSelection(with: sessions)
            await reloadTrustedHosts()
        } catch {
            present(error: error, fallback: "Trusted host connect failed")
        }
    }

    func createSession() async {
        busyMessage = "Creating session..."
        defer { busyMessage = nil }

        do {
            sessions = try await connectionManager.createSession(
                shellPath: nil,
                workingDirectory: nil,
                size: SessionWindowSize(rows: 40, columns: 120)
            )
            reconcileSelection(with: sessions)
        } catch {
            present(error: error, fallback: "Create session failed")
        }
    }

    func requestRename(for session: SessionSummary) {
        guard session.capabilities.supportsRename else {
            errorMessage = "This session is exposed as a read-only preview and cannot be renamed."
            return
        }

        renameTarget = session
        renameDraft = session.title
    }

    func submitRename() async {
        guard let target = renameTarget else { return }

        let trimmedTitle = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            errorMessage = "Session title cannot be empty."
            return
        }

        busyMessage = "Renaming session..."
        defer { busyMessage = nil }

        do {
            sessions = try await connectionManager.renameSession(id: target.id, title: trimmedTitle)
            reconcileSelection(with: sessions)
            renameTarget = nil
        } catch {
            present(error: error, fallback: "Rename failed")
        }
    }

    func closeSession(_ sessionID: SessionID) async {
        guard session(for: sessionID)?.capabilities.supportsClose != false else {
            errorMessage = "This session is exposed as a read-only preview and cannot be closed from the phone."
            return
        }

        busyMessage = "Closing session..."
        defer { busyMessage = nil }

        do {
            reportedViewportSizes.removeValue(forKey: sessionID)
            sessions = try await connectionManager.closeSession(id: sessionID)
            managedSessionTranscriptCache.removeValue(forKey: sessionID)
            managedSessionTranscriptCarryover.removeValue(forKey: sessionID)
            reconcileSelection(with: sessions)
            if selectedSessionID == sessionID {
                selectedSessionID = nil
                preferredSessionIDForReconnect = nil
                terminalText = ""
            }
        } catch {
            present(error: error, fallback: "Close failed")
        }
    }

    func requestCloseSessionConfirmation(_ session: SessionSummary) {
        guard session.capabilities.supportsClose else {
            errorMessage = "This session is exposed as a read-only preview and cannot be closed from the phone."
            return
        }

        pendingSensitiveAction = .closeSession(session.id)
        pendingSensitiveActionPrompt = SensitiveActionPrompt(
            title: "Close Session?",
            message: "This will terminate \"\(session.title)\" on the Mac and detach any connected client.",
            confirmButtonTitle: "Close Session",
            isDestructive: true
        )
    }

    func reconnect() async {
        busyMessage = "Reconnecting..."
        defer { busyMessage = nil }

        do {
            if let connectionDetails = currentConnectionDetails {
                try await ensureConnectivityAccessIfNeeded(
                    connectionMode: connectionDetails.connectionMode,
                    endpointKind: connectionDetails.endpointKind
                )
            } else if let lastConnectedHostID {
                await reloadTrustedHosts()
                if let trustedHost = trustedHosts.first(where: { $0.host.id == lastConnectedHostID }) {
                    try await ensureConnectivityAccessIfNeeded(for: trustedHost)
                }
            }
            do {
                let hello = try await connectionManager.reconnect()
                refreshConnectionDetails(from: hello)
            } catch {
                await reloadTrustedHosts()
                guard
                    let lastConnectedHostID,
                    let trustedHost = trustedHosts.first(where: { $0.host.id == lastConnectedHostID })
                else {
                    throw error
                }

                let hello = try await connectToTrustedHost(trustedHost)
                updateConnectionDetails(
                    host: hello.device,
                    hostAddress: trustedHost.hostAddress,
                    port: trustedHost.port,
                    connectionMode: hello.connectionMode ?? trustedHost.connectionMode,
                    endpointKind: hello.endpointKind ?? trustedHost.endpointKind,
                    previewAccessModes: hello.previewAccessModes ?? [],
                    trustExpiresAt: trustedHost.expiresAt
                )
            }
            sessions = try await connectionManager.listSessions()
            reconcileSelection(with: sessions)
            await restorePreferredSessionIfNeeded()
        } catch {
            present(error: error, fallback: "Reconnect failed")
        }
    }

    func disconnect() {
        performDisconnect()
    }

    func requestDisconnectConfirmation() {
        pendingSensitiveAction = .disconnect
        pendingSensitiveActionPrompt = SensitiveActionPrompt(
            title: "Disconnect From Mac?",
            message: selectedSessionID == nil
                ? "The app will disconnect from the current Mac."
                : "The app will disconnect from the current Mac and stop live interaction with the attached session.",
            confirmButtonTitle: "Disconnect",
            isDestructive: false
        )
    }

    private func performDisconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        explicitDisconnectRequested = true
        shouldRestoreConnection = false
        Task {
            await connectionManager.disconnect()
        }
        sessions = []
        selectedSessionID = nil
        preferredSessionIDForReconnect = nil
        terminalText = ""
        connectionStatusText = "Disconnected"
        reportedViewportSizes.removeAll()
        inputDiagnostics = InputDeliveryDiagnostics()
        currentConnectionDetails = nil
    }

    private func connectToTrustedHost(_ trustedHost: TrustedHostRecord) async throws -> HelloMessage {
        do {
            return try await connectionManager.connect(
                host: trustedHost.hostAddress,
                port: trustedHost.port,
                expectedHostPublicKey: trustedHost.publicKeyData
            )
        } catch let error as ClientConnectionError {
            guard
                trustedHost.port != Self.stableHostPort,
                shouldRetryTrustedHostConnection(error)
            else {
                throw error
            }

            return try await connectionManager.connect(
                host: trustedHost.hostAddress,
                port: Self.stableHostPort,
                expectedHostPublicKey: trustedHost.publicKeyData
            )
        }
    }

    func presentQRScanner() {
        isQRScannerPresented = true
    }

    func dismissQRScanner() {
        isQRScannerPresented = false
    }

    func handleScannedBootstrapPayload(_ payload: String) {
        let normalizedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard
            let data = normalizedPayload.data(using: .utf8),
            (try? decoder.decode(PairingBootstrapPayload.self, from: data)) != nil
        else {
            errorMessage = "Scanned QR code is not a valid pairing payload."
            return
        }

        bootstrapJSONString = normalizedPayload
        isQRScannerPresented = false

        Task {
            await connectUsingBootstrapJSONString()
        }
    }

    func handleQRScannerFailure(_ message: String) {
        isQRScannerPresented = false
        errorMessage = message
    }

    func sendPendingInput() async {
        guard allowInteractiveInput() else { return }
        let text = pendingInput
        pendingInput = ""
        await runProtectedAction(.sendComposer(text))
    }

    func sendText(_ text: String) async {
        guard allowInteractiveInput() else { return }
        guard let selectedSessionID, text.isEmpty == false else { return }
        let startedAt = ContinuousClock.now

        do {
            try await connectionManager.sendInput(sessionID: selectedSessionID, data: Data(text.utf8))
            recordInputSendResult(startedAt: startedAt, failure: nil)
        } catch {
            recordInputSendResult(startedAt: startedAt, failure: error)
            present(error: error, fallback: "Input failed")
        }
    }

    func sendSpecialKey(_ key: TerminalSpecialKey) async {
        guard allowInteractiveInput() else { return }
        guard let selectedSessionID else { return }
        let startedAt = ContinuousClock.now

        do {
            try await connectionManager.sendInput(sessionID: selectedSessionID, data: TerminalKeyInputEncoder.encode(key))
            recordInputSendResult(startedAt: startedAt, failure: nil)
        } catch {
            recordInputSendResult(startedAt: startedAt, failure: error)
            present(error: error, fallback: "Key input failed")
        }
    }

    func sendClipboardContents() async {
        guard allowInteractiveInput() else { return }
        guard let text = UIPasteboard.general.string, text.isEmpty == false else {
            errorMessage = "Clipboard is empty."
            return
        }

        await runProtectedAction(.pasteClipboard(text))
    }

    func confirmPendingPasteProtectionPrompt() async {
        guard let action = pendingProtectedAction else { return }
        pendingProtectedAction = nil
        pendingPasteProtectionPrompt = nil
        await perform(action)
    }

    func cancelPendingPasteProtectionPrompt() {
        pendingProtectedAction = nil
        pendingPasteProtectionPrompt = nil
    }

    func setViewOnlyModeEnabled(_ enabled: Bool) {
        guard enabled != viewOnlyModeEnabled else {
            return
        }

        if enabled == false {
            pendingSensitiveAction = .disableViewOnly
            pendingSensitiveActionPrompt = SensitiveActionPrompt(
                title: "Disable View-Only Mode?",
                message: "The app will allow terminal input, paste, and control-key actions again.",
                confirmButtonTitle: "Allow Input",
                isDestructive: false
            )
            return
        }

        viewOnlyModeEnabled = enabled
        userDefaults.set(enabled, forKey: Self.viewOnlyModeDefaultsKey)
        if enabled {
            pendingInput = ""
            cancelPendingPasteProtectionPrompt()
        }
    }

    func forgetTrustedHost(_ hostID: DeviceID) async {
        busyMessage = "Removing trusted Mac..."
        defer { busyMessage = nil }

        do {
            trustedHosts.removeAll { $0.host.id == hostID }
            try await trustedHostRegistry.revoke(hostID: hostID)
            if lastConnectedHostID == hostID {
                lastConnectedHostID = nil
                performDisconnect()
            }
            if currentConnectionDetails?.host.id == hostID {
                currentConnectionDetails = nil
            }
            await reloadTrustedHosts()
        } catch {
            present(error: error, fallback: "Failed to remove trusted Mac")
        }
    }

    func confirmPendingSensitiveAction() async {
        guard let action = pendingSensitiveAction else { return }
        pendingSensitiveAction = nil
        pendingSensitiveActionPrompt = nil

        switch action {
        case let .closeSession(sessionID):
            await closeSession(sessionID)
        case .disconnect:
            performDisconnect()
        case .disableViewOnly:
            viewOnlyModeEnabled = false
            userDefaults.set(false, forKey: Self.viewOnlyModeDefaultsKey)
        }
    }

    func cancelPendingSensitiveActionPrompt() {
        pendingSensitiveAction = nil
        pendingSensitiveActionPrompt = nil
    }

    func updateTerminalViewport(sessionID: SessionID, availableSize: CGSize) async {
        guard session(for: sessionID)?.capabilities.supportsResize != false else {
            return
        }

        guard availableSize.width.isFinite, availableSize.height.isFinite else {
            return
        }

        guard availableSize.width > 0, availableSize.height > 0 else {
            return
        }

        let estimatedSize = estimateTerminalWindowSize(for: availableSize)
        guard estimatedSize.rows > 0, estimatedSize.columns > 0 else {
            return
        }

        if reportedViewportSizes[sessionID] == estimatedSize {
            return
        }

        do {
            _ = try await connectionManager.resizeSession(id: sessionID, size: estimatedSize)
            reportedViewportSizes[sessionID] = estimatedSize
        } catch {
            present(error: error, fallback: "Resize failed")
        }
    }

    func shouldReuseAttachedSession(_ sessionID: SessionID) -> Bool {
        guard selectedSessionID == sessionID else {
            return false
        }

        guard let session = session(for: sessionID), session.capabilities.supportsInput else {
            return false
        }

        return terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func detachSessionIfNeeded(_ sessionID: SessionID) async {
        guard selectedSessionID == sessionID || preferredSessionIDForReconnect == sessionID else {
            return
        }

        guard let session = session(for: sessionID) else {
            return
        }

        if session.capabilities.supportsInput,
           terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            managedSessionTranscriptCache[sessionID] = terminalText
        }

        selectedSessionID = nil
        preferredSessionIDForReconnect = nil
        reportedViewportSizes.removeValue(forKey: sessionID)
        terminalText = ""
        await buffer.clear()

        guard case .connected = await connectionManager.currentState() else {
            return
        }

        do {
            sessions = try await connectionManager.detachSession(id: sessionID)
        } catch {
            // Detach happens during navigation away from the terminal screen. If the
            // connection is already gone, keep local state cleared and avoid surfacing
            // a noisy error alert during the back transition.
        }
    }

    private func connect(using bootstrap: PairingBootstrapPayload) async throws {
        explicitDisconnectRequested = false
        let hello = try await connectionManager.connect(using: bootstrap)
        updateConnectionDetails(
            host: hello.device,
            hostAddress: bootstrap.host,
            port: bootstrap.port,
            connectionMode: hello.connectionMode ?? bootstrap.connectionMode,
            endpointKind: hello.endpointKind ?? bootstrap.endpointKind,
            previewAccessModes: hello.previewAccessModes ?? [],
            trustExpiresAt: nil
        )
        if await isTrustedHost(bootstrap.hostIdentity, publicKey: bootstrap.hostPublicKey) == false {
            let pairResponse = try await connectionManager.pair(using: bootstrap.token)
            connectionStatusText = "Pairing \(pairResponse.status.rawValue)"
        } else {
            do {
                let pairResponse = try await connectionManager.pair(using: bootstrap.token)
                connectionStatusText = "Pairing \(pairResponse.status.rawValue)"
            } catch let ClientConnectionError.protocolError(error)
                where error.code == .unauthorized
            {
                connectionStatusText = "Connected to \(bootstrap.hostIdentity.name)"
            }
        }
        sessions = try await connectionManager.listSessions()
        reconcileSelection(with: sessions)
        await reloadTrustedHosts()
    }

    private func isTrustedHost(_ hostIdentity: DeviceIdentity, publicKey: Data) async -> Bool {
        guard let record = await trustedHostRegistry.record(for: hostIdentity.id) else {
            return false
        }

        return record.publicKeyData == publicKey
    }

    private func reloadTrustedHosts() async {
        trustedHosts = await trustedHostRegistry.allHosts()
        refreshConnectionDetails()
    }

    private func performAttachSession(_ sessionID: SessionID) async throws {
        try await ensureConnectedForSessionOperation()
        let targetSession = session(for: sessionID)
        await buffer.clear()
        if let targetSession, targetSession.capabilities.supportsInput == false {
            managedSessionTranscriptCarryover.removeValue(forKey: sessionID)
            let preview = targetSession.previewExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if preview.isEmpty {
                terminalText = "Loading preview from \(targetSession.title)..."
            } else {
                terminalText = "\(preview)\n\nLoading preview from \(targetSession.title)..."
            }
        } else {
            let cachedTranscript = managedSessionTranscriptCache[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let initialTranscript = cachedTranscript?.isEmpty == false ? cachedTranscript! : ""
            managedSessionTranscriptCarryover[sessionID] = initialTranscript
            terminalText = initialTranscript
        }
        selectedSessionID = sessionID
        preferredSessionIDForReconnect = sessionID
        shouldRestoreConnection = true
        sessions = try await connectionManager.attachSession(id: sessionID)
        reconcileSelection(with: sessions)
        let snapshot = await buffer.snapshot()
        let transcript = await buffer.transcriptText()
        if let targetSession, targetSession.capabilities.supportsInput == false {
            let rendered = snapshot.renderedText(showCursor: true)
            if rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                terminalText = rendered
            }
        } else {
            let combinedTranscript = combinedManagedTranscript(for: sessionID, liveTranscript: transcript)
            terminalText = combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? snapshot.renderedText(showCursor: true)
                : combinedTranscript
            managedSessionTranscriptCache[sessionID] = terminalText
        }
    }

    private func ensureConnectedForSessionOperation() async throws {
        switch await connectionManager.currentState() {
        case .connected:
            return
        case .connecting:
            throw ClientConnectionError.serviceUnavailable
        case .disconnected:
            break
        }

        guard shouldRestoreConnection, explicitDisconnectRequested == false else {
            throw ClientConnectionError.noConnection
        }

        do {
            let hello = try await connectionManager.reconnect()
            refreshConnectionDetails(from: hello)
        } catch {
            await reloadTrustedHosts()
            guard
                let lastConnectedHostID,
                let trustedHost = trustedHosts.first(where: { $0.host.id == lastConnectedHostID })
            else {
                throw error
            }

            let hello = try await connectToTrustedHost(trustedHost)
            updateConnectionDetails(
                host: hello.device,
                hostAddress: trustedHost.hostAddress,
                port: trustedHost.port,
                connectionMode: hello.connectionMode ?? trustedHost.connectionMode,
                endpointKind: hello.endpointKind ?? trustedHost.endpointKind,
                previewAccessModes: hello.previewAccessModes ?? [],
                trustExpiresAt: trustedHost.expiresAt
            )
        }

        sessions = try await connectionManager.listSessions()
        reconcileSelection(with: sessions)
    }

    private func reconnectForSessionOperation() async throws {
        try await ensureConnectedForSessionOperation()
    }

    private func ensureLocalNetworkAccess() async throws {
        if case .granted = localNetworkAccessState {
            return
        }

        localNetworkAccessState = .requesting
        connectionStatusText = "Requesting local network access"

        do {
            _ = try await localNetworkAuthorizer.requestAccess(forceRetry: true)
            localNetworkAccessState = .granted
        } catch {
            let message = userFacingMessage(for: error, fallback: "Local network access failed")
            localNetworkAccessState = .denied(message)
            throw error
        }
    }

    private func ensureConnectivityAccessIfNeeded(for trustedHost: TrustedHostRecord) async throws {
        try await ensureConnectivityAccessIfNeeded(
            connectionMode: trustedHost.connectionMode,
            endpointKind: trustedHost.endpointKind
        )
    }

    private func ensureConnectivityAccessIfNeeded(
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind
    ) async throws {
        guard requiresLocalNetworkAccess(connectionMode: connectionMode, endpointKind: endpointKind) else {
            return
        }

        try await ensureLocalNetworkAccess()
    }

    private func allowInteractiveInput() -> Bool {
        if viewOnlyModeEnabled {
            errorMessage = "View-only mode is enabled. Disable it to send input."
            return false
        }

        if let selectedSession = selectedSessionID.flatMap(session(for:)), selectedSession.capabilities.supportsInput == false {
            errorMessage = "This is an existing Terminal/iTerm window preview. Create or open a managed session for interactive control."
            return false
        }

        return true
    }

    func session(for sessionID: SessionID) -> SessionSummary? {
        sessions.first(where: { $0.id == sessionID })
    }

    private func pasteGuardPolicy() -> PasteGuardPolicy {
        guard pasteProtectionEnabled else {
            return PasteGuardPolicy(
                largePasteByteThreshold: .max,
                multilineThreshold: .max,
                warnOnEscapeSequences: false
            )
        }

        return PasteGuardPolicy(
            largePasteByteThreshold: 256,
            multilineThreshold: 2,
            warnOnEscapeSequences: warnOnEscapeSequences
        )
    }

    private func runProtectedAction(_ action: ProtectedTerminalAction) async {
        let data = action.payload
        switch pasteGuardPolicy().evaluate(data) {
        case .allow:
            await perform(action)
        case let .confirmLargePaste(lineCount, byteCount):
            pendingProtectedAction = action
            pendingPasteProtectionPrompt = PasteProtectionPrompt(
                title: "Confirm Paste",
                message: "This input contains \(lineCount) lines and \(byteCount) bytes. Send it to the terminal?"
            )
        case .confirmControlSequence:
            pendingProtectedAction = action
            pendingPasteProtectionPrompt = PasteProtectionPrompt(
                title: "Control Sequence Detected",
                message: "This input contains escape or control sequences. Send it to the terminal?"
            )
        }
    }

    private func perform(_ action: ProtectedTerminalAction) async {
        switch action {
        case let .sendComposer(text):
            await sendText(text)
            await sendSpecialKey(.enter)
        case let .pasteClipboard(text):
            await sendText(text)
        }
    }

    private func present(error: Error, fallback: String) {
        errorMessage = userFacingMessage(for: error, fallback: fallback)
        connectionStatusText = errorMessage ?? fallback
    }

    private func updateConnectionDetails(
        host: DeviceIdentity,
        hostAddress: String,
        port: UInt16,
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind,
        previewAccessModes: [HostConnectionMode],
        trustExpiresAt: Date?
    ) {
        currentConnectionDetails = HostConnectionDetails(
            host: host,
            hostAddress: hostAddress,
            port: port,
            connectionMode: connectionMode,
            endpointKind: endpointKind,
            previewAccessModes: previewAccessModes,
            trustExpiresAt: trustExpiresAt
        )
    }

    private func refreshConnectionDetails() {
        guard let hostID = lastConnectedHostID else {
            return
        }

        guard let trustedHost = trustedHosts.first(where: { $0.host.id == hostID }) else {
            return
        }

        updateConnectionDetails(
            host: trustedHost.host,
            hostAddress: trustedHost.hostAddress,
            port: trustedHost.port,
            connectionMode: trustedHost.connectionMode,
            endpointKind: trustedHost.endpointKind,
            previewAccessModes: currentConnectionDetails?.previewAccessModes ?? [],
            trustExpiresAt: trustedHost.expiresAt
        )
    }

    private func refreshConnectionDetails(from hello: HelloMessage) {
        guard let hostID = lastConnectedHostID else {
            return
        }

        if let trustedHost = trustedHosts.first(where: { $0.host.id == hostID }) {
            updateConnectionDetails(
                host: hello.device,
                hostAddress: trustedHost.hostAddress,
                port: trustedHost.port,
                connectionMode: hello.connectionMode ?? trustedHost.connectionMode,
                endpointKind: hello.endpointKind ?? trustedHost.endpointKind,
                previewAccessModes: hello.previewAccessModes ?? currentConnectionDetails?.previewAccessModes ?? [],
                trustExpiresAt: trustedHost.expiresAt
            )
            return
        }

        if let existing = currentConnectionDetails {
            updateConnectionDetails(
                host: hello.device,
                hostAddress: existing.hostAddress,
                port: existing.port,
                connectionMode: hello.connectionMode ?? existing.connectionMode,
                endpointKind: hello.endpointKind ?? existing.endpointKind,
                previewAccessModes: hello.previewAccessModes ?? existing.previewAccessModes,
                trustExpiresAt: existing.trustExpiresAt
            )
        }
    }

    private func estimateTerminalWindowSize(for availableSize: CGSize) -> SessionWindowSize {
        guard availableSize.width.isFinite, availableSize.height.isFinite else {
            return SessionWindowSize(rows: 0, columns: 0)
        }

        let horizontalInset: CGFloat = 24
        let verticalInset: CGFloat = 24
        let estimatedCharacterWidth: CGFloat = 8.5
        let estimatedLineHeight: CGFloat = 18

        let usableWidth = max(availableSize.width - horizontalInset, estimatedCharacterWidth)
        let usableHeight = max(availableSize.height - verticalInset, estimatedLineHeight)
        let columns = min(max(Int(usableWidth / estimatedCharacterWidth), 40), 240)
        let rows = min(max(Int(usableHeight / estimatedLineHeight), 10), 120)

        return SessionWindowSize(rows: UInt16(rows), columns: UInt16(columns))
    }

    private func recordInputSendResult(startedAt: ContinuousClock.Instant, failure: Error?) {
        let duration = ContinuousClock.now - startedAt
        let latencyMilliseconds = Int(duration.components.seconds * 1_000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)

        inputDiagnostics.lastSendLatencyMilliseconds = max(0, latencyMilliseconds)
        if let failure {
            inputDiagnostics.failedEventCount += 1
            inputDiagnostics.lastFailureSummary = shortErrorSummary(for: failure)
        } else {
            inputDiagnostics.successfulEventCount += 1
            inputDiagnostics.lastFailureSummary = nil
        }
    }

    private func userFacingMessage(for error: Error, fallback: String) -> String {
        if let error = error as? ClientConnectionError {
            switch error {
            case .timedOut:
                return "\(fallback): The Mac did not answer before the request timed out."
            case .serviceUnavailable:
                return "\(fallback): The Mac is unreachable on the local network."
            case .hostIdentityMismatch:
                return "\(fallback): The Mac identity no longer matches the trusted device record."
            case .missingHostPublicKey:
                return "\(fallback): The Mac did not present a signing key."
            case let .protocolError(protocolError):
                if protocolError.code == .unsupportedOperation {
                    return protocolError.message
                }
                return "\(fallback): \(protocolError.message)"
            case let .networkFailure(summary):
                return "\(fallback): Network error (\(summary))."
            case .noConnection:
                return "\(fallback): No active connection to the Mac."
            case .unexpectedReply:
                return "\(fallback): The Mac sent an unexpected response."
            }
        }

        let description = (error as NSError).localizedDescription
        return "\(fallback): \(description)"
    }

    private func shortErrorSummary(for error: Error) -> String {
        if let error = error as? ClientConnectionError {
            switch error {
            case .timedOut:
                return "timed out"
            case .serviceUnavailable:
                return "unreachable"
            case .networkFailure:
                return "network"
            case .hostIdentityMismatch:
                return "identity mismatch"
            case .missingHostPublicKey:
                return "missing host key"
            case .protocolError:
                return "protocol"
            case .noConnection:
                return "disconnected"
            case .unexpectedReply:
                return "unexpected reply"
            }
        }

        return "send failed"
    }

    private func scheduleAutoReconnect(reason: String) {
        guard shouldRestoreConnection, explicitDisconnectRequested == false else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(APTerminalConfiguration.defaultAutoReconnectDelayMilliseconds))
            guard Task.isCancelled == false else { return }
            await self.performAutoReconnect(reason: reason)
        }
    }

    private func performAutoReconnect(reason: String) async {
        guard busyMessage == nil else { return }
        guard shouldRestoreConnection, explicitDisconnectRequested == false else { return }

        busyMessage = reason
        defer { busyMessage = nil }

        do {
            if let connectionDetails = currentConnectionDetails {
                try await ensureConnectivityAccessIfNeeded(
                    connectionMode: connectionDetails.connectionMode,
                    endpointKind: connectionDetails.endpointKind
                )
            }

            let hello = try await connectionManager.reconnect()
            refreshConnectionDetails(from: hello)
        } catch {
            await reloadTrustedHosts()
            guard
                let lastConnectedHostID,
                let trustedHost = trustedHosts.first(where: { $0.host.id == lastConnectedHostID })
            else {
                present(error: error, fallback: "Auto reconnect failed")
                return
            }

            do {
                try await ensureConnectivityAccessIfNeeded(for: trustedHost)
                let hello = try await connectToTrustedHost(trustedHost)
                updateConnectionDetails(
                    host: hello.device,
                    hostAddress: trustedHost.hostAddress,
                    port: trustedHost.port,
                    connectionMode: hello.connectionMode ?? trustedHost.connectionMode,
                    endpointKind: hello.endpointKind ?? trustedHost.endpointKind,
                    previewAccessModes: hello.previewAccessModes ?? [],
                    trustExpiresAt: trustedHost.expiresAt
                )
            } catch {
                present(error: error, fallback: "Auto reconnect failed")
                return
            }
        }

        do {
            sessions = try await connectionManager.listSessions()
            reconcileSelection(with: sessions)
            await restorePreferredSessionIfNeeded()
            connectionStatusText = "Recovered connection"
        } catch {
            present(error: error, fallback: "Session recovery failed")
        }
    }

    private func restorePreferredSessionIfNeeded() async {
        guard let preferredSessionIDForReconnect else { return }
        guard sessions.contains(where: { $0.id == preferredSessionIDForReconnect }) else {
            terminalText = "[Session no longer exists on the Mac]"
            self.preferredSessionIDForReconnect = nil
            return
        }

        do {
            selectedSessionID = preferredSessionIDForReconnect
            await buffer.clear()
            terminalText = ""
            sessions = try await connectionManager.attachSession(id: preferredSessionIDForReconnect)
            reconcileSelection(with: sessions)
        } catch {
            reconcileAfterRecoverableSessionFailure(for: preferredSessionIDForReconnect)
            present(error: error, fallback: "Session restore failed")
        }
    }

    private func reconcileSelection(with sessions: [SessionSummary]) {
        guard let selectedSessionID = preferredSessionIDForReconnect ?? selectedSessionID else {
            return
        }

        guard let session = sessions.first(where: { $0.id == selectedSessionID }) else {
            self.selectedSessionID = nil
            self.preferredSessionIDForReconnect = nil
            terminalText = "[Session no longer exists on the Mac]"
            return
        }

        if session.state == .exited || session.state == .failed {
            self.selectedSessionID = nil
            self.preferredSessionIDForReconnect = nil
            terminalText = "[Session exited on the Mac]"
            return
        }

        self.selectedSessionID = session.id
        self.preferredSessionIDForReconnect = session.id
    }

    private func reconcileAfterRecoverableSessionFailure(for sessionID: SessionID) {
        selectedSessionID = nil
        preferredSessionIDForReconnect = nil
        reportedViewportSizes.removeValue(forKey: sessionID)
        managedSessionTranscriptCarryover.removeValue(forKey: sessionID)
        terminalText = "[Session is unavailable]"
    }

    private var isConnectedStatusText: Bool {
        let normalized = connectionStatusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("connected") || normalized.hasPrefix("recovered")
    }

    private func shouldReconcileAfterAttachFailure(_ error: Error) -> Bool {
        guard let error = error as? ClientConnectionError else {
            return false
        }

        switch error {
        case let .protocolError(protocolError):
            return protocolError.code == .sessionNotFound || protocolError.code == .invalidState
        case .serviceUnavailable, .timedOut, .noConnection:
            return true
        case .networkFailure, .hostIdentityMismatch, .missingHostPublicKey, .unexpectedReply:
            return false
        }
    }

    private func shouldRetryAttachAfterReconnect(_ error: Error) -> Bool {
        guard let error = error as? ClientConnectionError else {
            return false
        }

        switch error {
        case .noConnection, .timedOut, .serviceUnavailable, .networkFailure:
            return true
        case .hostIdentityMismatch, .missingHostPublicKey, .unexpectedReply:
            return false
        case let .protocolError(protocolError):
            return protocolError.code == .internalFailure
        }
    }

    private func shouldRetryTrustedHostConnection(_ error: ClientConnectionError) -> Bool {
        switch error {
        case .timedOut, .serviceUnavailable, .networkFailure, .noConnection:
            return true
        case .hostIdentityMismatch, .missingHostPublicKey, .unexpectedReply, .protocolError:
            return false
        }
    }

    private func combinedManagedTranscript(for sessionID: SessionID, liveTranscript: String) -> String {
        let base = managedSessionTranscriptCarryover[sessionID] ?? ""
        let trimmedLive = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard base.isEmpty == false else {
            return liveTranscript
        }

        guard trimmedLive.isEmpty == false else {
            return base
        }

        if base.hasSuffix("\n") || liveTranscript.hasPrefix("\n") {
            return base + liveTranscript
        }

        return base + "\n" + liveTranscript
    }

}

extension iOSClientAppModel {
    var connectionTroubleshootingHints: [String] {
        var hints: [String] = []

        if currentConnectionDetails?.connectionMode == .internetVPN {
            hints.append(contentsOf: [
                "Confirm the Mac is signed into Tailscale and still on the tailnet.",
                "Confirm the iPhone is signed into the same tailnet.",
                "Check that your Tailnet ACL or Grant allows the APTerminal port.",
                "If Tailnet Lock is enabled, verify both devices are approved."
            ])
        }

        if currentConnectionDetails?.previewAccessModes.isEmpty == true {
            hints.append("Ask the Mac owner to grant preview access in Devices if you need Terminal or iTerm previews.")
        }

        return hints
    }

    fileprivate func requiresLocalNetworkAccess(
        connectionMode: HostConnectionMode,
        endpointKind: HostEndpointKind
    ) -> Bool {
        connectionMode == .lan || endpointKind == .localNetwork
    }
}

private enum ProtectedTerminalAction {
    case sendComposer(String)
    case pasteClipboard(String)

    var payload: Data {
        switch self {
        case let .sendComposer(text), let .pasteClipboard(text):
            return Data(text.utf8)
        }
    }
}

private enum SensitiveAction {
    case closeSession(SessionID)
    case disconnect
    case disableViewOnly
}
