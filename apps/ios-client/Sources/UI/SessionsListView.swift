import SwiftUI
import APTerminalProtocol
import APTerminalSecurity
import UIKit

struct SessionsListView: View {
    private struct SessionRoute: Identifiable, Hashable {
        let session: SessionSummary

        var id: SessionID { session.id }

        static func == (lhs: SessionRoute, rhs: SessionRoute) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    @ObservedObject var model: iOSClientAppModel
    @EnvironmentObject private var appLockManager: AppLockManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isBootstrapFocused: Bool
    @State private var activeSessionRoute: SessionRoute?

    var body: some View {
        GeometryReader { proxy in
            let metrics = DashboardMetrics(width: proxy.size.width, dynamicTypeSize: dynamicTypeSize)

            ZStack {
                ClientTheme.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: metrics.sectionSpacing) {
                        headerBar(metrics: metrics)
                        connectionCard
                        if let connectionDetails = model.currentConnectionDetails {
                            connectionDetailsCard(connectionDetails)
                        }

                        if model.trustedHosts.isEmpty {
                            pairingCard
                        } else {
                            trustedHostsCard
                        }

                        sessionsCard

                        securityCard
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, metrics.bottomInsetPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom) {
                    if shouldShowBottomBar {
                        bottomBar(metrics: metrics)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.renameTarget != nil },
            set: { isPresented in
                if isPresented == false {
                    model.renameTarget = nil
                }
            }
        )) {
            RenameSessionSheet(
                session: model.renameTarget,
                draft: $model.renameDraft,
                onCancel: {
                    model.renameTarget = nil
                },
                onSave: {
                    Task {
                        await model.submitRename()
                    }
                }
            )
            .presentationDetents([.height(240)])
            .presentationDragIndicator(.visible)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil && model.renameTarget == nil && model.pendingSensitiveActionPrompt == nil },
            set: { isPresented in
                if isPresented == false {
                    model.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            model.pendingSensitiveActionPrompt?.title ?? "Confirm Action",
            isPresented: Binding(
                get: { model.pendingSensitiveActionPrompt != nil },
                set: { isPresented in
                    if isPresented == false {
                        model.cancelPendingSensitiveActionPrompt()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let prompt = model.pendingSensitiveActionPrompt {
                Button(prompt.confirmButtonTitle, role: prompt.isDestructive ? .destructive : nil) {
                    Task {
                        await model.confirmPendingSensitiveAction()
                        appLockManager.markActivity()
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                model.cancelPendingSensitiveActionPrompt()
            }
        } message: {
            Text(model.pendingSensitiveActionPrompt?.message ?? "")
        }
        .sheet(isPresented: $model.isQRScannerPresented) {
            BootstrapQRScannerSheet(
                onPayloadScanned: { payload in
                    model.handleScannedBootstrapPayload(payload)
                    appLockManager.markActivity()
                },
                onScannerFailure: { message in
                    model.handleQRScannerFailure(message)
                },
                onCancel: {
                    model.dismissQRScanner()
                }
            )
        }
        .overlay {
            if let busyMessage = model.busyMessage {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()

                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(ClientTheme.textPrimary)
                        Text(busyMessage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ClientTheme.textPrimary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(ClientTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(ClientTheme.border, lineWidth: 1)
                    }
                }
            }
        }
        .task {
            model.startDiscovery()
        }
        .navigationDestination(item: $activeSessionRoute) { route in
            TerminalView(
                model: model,
                session: model.session(for: route.session.id) ?? route.session
            )
        }
        .disabled(model.busyMessage != nil)
        .dynamicTypeSize(.xSmall ... .xLarge)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headerBar(metrics: DashboardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("APTerminal")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(ClientTheme.textPrimary)
                Text("Terminal control tuned for your iPhone.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(ClientTheme.textSecondary)
            }

            HStack(spacing: 8) {
                overviewPill(
                    title: isConnectedStatus ? "Online" : "Offline",
                    value: isConnectedStatus ? "Ready" : "Need Access",
                    tint: connectionTint
                )
                overviewPill(title: "Sessions", value: "\(model.sessions.count)", tint: ClientTheme.accentSecondary)

                if model.trustedHosts.isEmpty == false {
                    overviewPill(title: "Trusted Macs", value: "\(model.trustedHosts.count)", tint: ClientTheme.accent)
                }
            }
        }
        .padding(.top, metrics.headerTopPadding)
    }

    private var connectionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(connectionTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ClientTheme.textPrimary)
                        Text(model.connectionStatusText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(ClientTheme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Text(model.localNetworkAccessState.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(localNetworkTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(localNetworkTint.opacity(0.14), in: Capsule())
                }

                Text(model.localNetworkAccessState.detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ClientTheme.textSecondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryButton(
                            title: permissionButtonTitle,
                            systemImage: "wifi",
                            tint: localNetworkTint
                        ) {
                            Task {
                                await model.requestLocalNetworkAccess()
                                appLockManager.markActivity()
                            }
                        }

                        if case .denied = model.localNetworkAccessState {
                            secondaryButton(title: "Settings", systemImage: "gearshape") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        primaryButton(
                            title: permissionButtonTitle,
                            systemImage: "wifi",
                            tint: localNetworkTint
                        ) {
                            Task {
                                await model.requestLocalNetworkAccess()
                                appLockManager.markActivity()
                            }
                        }

                        if case .denied = model.localNetworkAccessState {
                            secondaryButton(title: "Open Settings", systemImage: "gearshape") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var pairingCard: some View {
        card(title: "Pair Your Mac", subtitle: "Paste the bootstrap JSON or scan the QR code from the Mac app.") {
            VStack(spacing: 10) {
                TextEditor(text: $model.bootstrapJSONString)
                    .focused($isBootstrapFocused)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(ClientTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(8)
                    .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ClientTheme.border, lineWidth: 1)
                    }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        secondaryButton(title: "Scan QR", systemImage: "qrcode.viewfinder") {
                            model.presentQRScanner()
                        }

                        primaryButton(title: "Connect", systemImage: "link", tint: ClientTheme.accentSecondary) {
                            Task {
                                await model.connectUsingBootstrapJSONString()
                                appLockManager.markActivity()
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        secondaryButton(title: "Scan QR", systemImage: "qrcode.viewfinder") {
                            model.presentQRScanner()
                        }

                        primaryButton(title: "Connect", systemImage: "link", tint: ClientTheme.accentSecondary) {
                            Task {
                                await model.connectUsingBootstrapJSONString()
                                appLockManager.markActivity()
                            }
                        }
                    }
                }
            }
        }
    }

    private func connectionDetailsCard(_ details: HostConnectionDetails) -> some View {
        card(title: "Connection Details", subtitle: "Current host identity, endpoint, and trust state.") {
            VStack(alignment: .leading, spacing: 10) {
                Text(details.host.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClientTheme.textPrimary)

                detailRow(title: "Endpoint", value: "\(details.hostAddress):\(details.port)")
                detailRow(title: "Mode", value: details.connectionMode.displayName)
                detailRow(title: "Endpoint Type", value: details.endpointKind.displayName)
                detailRow(title: "Preview Access", value: previewAccessLabel(for: details))
                detailRow(
                    title: "Trust Expires",
                    value: details.trustExpiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "Pending pair"
                )

                if model.connectionTroubleshootingHints.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Troubleshooting")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClientTheme.textMuted)

                        ForEach(model.connectionTroubleshootingHints, id: \.self) { hint in
                            Text("• \(hint)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(ClientTheme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var trustedHostsCard: some View {
        card(title: "Trusted Macs", subtitle: "Reconnect quickly without pairing again.") {
            VStack(spacing: 10) {
                ForEach(model.trustedHosts, id: \.host.id) { host in
                    hostRow(host)
                }
            }
        }
    }

    private func hostRow(_ host: TrustedHostRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.host.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClientTheme.textPrimary)
                    Text("\(host.hostAddress):\(host.port)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ClientTheme.textSecondary)
                        .lineLimit(1)
                    Text("\(host.connectionMode.displayName) • \(host.endpointKind.displayName)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(ClientTheme.textMuted)
                }

                Spacer()
            }

            if let lastSeenAt = host.lastSeenAt {
                Text("Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ClientTheme.textMuted)
            }

            Text("Trust expires \(host.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ClientTheme.textMuted)

            HStack(spacing: 10) {
                primaryButton(title: "Connect", systemImage: "arrow.up.right.square", tint: ClientTheme.accentSecondary) {
                    Task {
                        await model.connect(to: host)
                        appLockManager.markActivity()
                    }
                }

                secondaryButton(title: "Remove Trust", systemImage: "trash") {
                    Task {
                        await model.forgetTrustedHost(host.host.id)
                        appLockManager.markActivity()
                    }
                }
            }
        }
        .padding(12)
        .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private func previewAccessLabel(for details: HostConnectionDetails) -> String {
        let modes = details.previewAccessModes
        guard modes.isEmpty == false else {
            return "Base access only"
        }

        if modes.count == HostConnectionMode.allCases.count {
            return "All modes"
        }

        return modes.map(\.displayName).joined(separator: ", ")
    }

    private var sessionsCard: some View {
        card(
            title: "Sessions",
            subtitle: model.sessions.isEmpty
                ? nil
                : "Open a session to inspect output and send input."
        ) {
            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No sessions yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClientTheme.textPrimary)
                    Text("Create a managed shell, or open Terminal/iTerm on your Mac to expose existing windows as read-only previews.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(ClientTheme.textSecondary)

                    primaryButton(title: "Create Session", systemImage: "plus", tint: ClientTheme.accent) {
                        Task {
                            await model.createSession()
                            appLockManager.markActivity()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.sessions, id: \.id) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ClientTheme.textPrimary)
                        sourceBadge(session.source)
                        stateBadge(session.state)
                    }

                    Text(session.workingDirectory)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ClientTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if session.previewExcerpt.isEmpty == false {
                Text(session.previewExcerpt)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ClientTheme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        if model.shouldReuseAttachedSession(session.id) {
                            activeSessionRoute = SessionRoute(session: model.session(for: session.id) ?? session)
                            appLockManager.markActivity()
                            return
                        }

                        await model.attachSession(session.id)
                        if model.selectedSessionID == session.id {
                            activeSessionRoute = SessionRoute(session: model.session(for: session.id) ?? session)
                            appLockManager.markActivity()
                        }
                    }
                } label: {
                    Label(session.capabilities.supportsInput ? "Open terminal" : "Open preview", systemImage: "chevron.right.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClientTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                if model.selectedSessionID == session.id {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ClientTheme.accent)
                }
            }

            HStack(spacing: 10) {
                if session.capabilities.supportsRename {
                    secondaryButton(title: "Rename", systemImage: "pencil") {
                        model.requestRename(for: session)
                    }
                }

                if session.capabilities.supportsClose {
                    secondaryButton(title: "Close", systemImage: "xmark") {
                        Task {
                            await model.closeSession(session.id)
                            appLockManager.markActivity()
                        }
                    }
                }

                if session.isReadOnlyPreview {
                    Text("Read-only existing app window")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClientTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private var securityCard: some View {
        card(title: "Security", subtitle: "Compact safeguards for phone control.") {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Idle Lock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClientTheme.textMuted)

                    Picker(
                        "Idle Lock",
                        selection: Binding(
                            get: { appLockManager.idleTimeout },
                            set: { appLockManager.updateIdleTimeout($0) }
                        )
                    ) {
                        ForEach(AppLockManager.idleTimeoutOptions) { option in
                            Text(option.title).tag(option.seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                }

                settingToggleRow(
                    title: "View-only mode",
                    subtitle: "Blocks keyboard input until you re-enable interaction.",
                    isOn: Binding(
                        get: { model.viewOnlyModeEnabled },
                        set: { model.setViewOnlyModeEnabled($0) }
                    )
                )

                settingToggleRow(
                    title: "Paste protection",
                    subtitle: "Warns before large or multiline input is sent.",
                    isOn: $model.pasteProtectionEnabled
                )

                settingToggleRow(
                    title: "Escape warnings",
                    subtitle: "Warns when pasted input contains escape sequences.",
                    isOn: $model.warnOnEscapeSequences
                )
            }
        }
    }

    private func bottomBar(metrics: DashboardMetrics) -> some View {
        VStack(spacing: 8) {
            if metrics.prefersStackedActions {
                HStack(spacing: 10) {
                    footerActionButton(title: "Reconnect", systemImage: "arrow.clockwise", tint: ClientTheme.accentSecondary) {
                        Task {
                            await model.reconnect()
                            appLockManager.markActivity()
                        }
                    }

                    if model.trustedHosts.isEmpty == false {
                        footerActionButton(title: "New Session", systemImage: "plus", tint: ClientTheme.accent) {
                            Task {
                                await model.createSession()
                                appLockManager.markActivity()
                            }
                        }
                    }
                }

                footerSecondaryButton(title: "Disconnect", systemImage: "xmark.circle") {
                    model.requestDisconnectConfirmation()
                }
            } else {
                HStack(spacing: 10) {
                    footerActionButton(title: "Reconnect", systemImage: "arrow.clockwise", tint: ClientTheme.accentSecondary) {
                        Task {
                            await model.reconnect()
                            appLockManager.markActivity()
                        }
                    }

                    if model.trustedHosts.isEmpty == false {
                        footerActionButton(title: "New Session", systemImage: "plus", tint: ClientTheme.accent) {
                            Task {
                                await model.createSession()
                                appLockManager.markActivity()
                            }
                        }
                    }

                    footerSecondaryButton(title: "Disconnect", systemImage: "xmark.circle") {
                        model.requestDisconnectConfirmation()
                    }
                }
            }
        }
        .padding(10)
        .background(ClientTheme.surfaceRaised.opacity(0.97), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, metrics.bottomDockBottomPadding)
    }

    private var shouldShowBottomBar: Bool {
        model.trustedHosts.isEmpty == false || model.sessions.isEmpty == false
    }

    private var permissionButtonTitle: String {
        switch model.localNetworkAccessState {
        case .granted:
            return "Recheck"
        case .requesting:
            return "Waiting"
        case .unknown, .denied:
            return "Request Access"
        }
    }

    private var connectionTitle: String {
        if isConnectedStatus {
            return "Connected"
        }

        return "Connection Needed"
    }

    private var connectionTint: Color {
        isConnectedStatus ? ClientTheme.accent : ClientTheme.warning
    }

    private var localNetworkTint: Color {
        switch model.localNetworkAccessState {
        case .granted:
            return ClientTheme.accent
        case .requesting:
            return ClientTheme.accentSecondary
        case .unknown:
            return ClientTheme.warning
        case .denied:
            return ClientTheme.danger
        }
    }

    private var isConnectedStatus: Bool {
        let normalized = model.connectionStatusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("connected") || normalized.hasPrefix("recovered")
    }

    private func stateBadge(_ state: SessionState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor(for: state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stateColor(for: state).opacity(0.16), in: Capsule())
    }

    private func sourceBadge(_ source: SessionSource) -> some View {
        Text(sourceTitle(for: source))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(sourceColor(for: source))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(sourceColor(for: source).opacity(0.16), in: Capsule())
    }

    private func stateColor(for state: SessionState) -> Color {
        switch state {
        case .starting:
            return ClientTheme.accentSecondary
        case .running:
            return ClientTheme.accent
        case .attached:
            return Color(red: 0.56, green: 0.52, blue: 0.95)
        case .closing:
            return ClientTheme.warning
        case .failed:
            return ClientTheme.danger
        case .exited:
            return ClientTheme.textMuted
        }
    }

    private func sourceTitle(for source: SessionSource) -> String {
        switch source {
        case .managed:
            return "Managed"
        case .terminalApp:
            return "Terminal"
        case .iTermApp:
            return "iTerm"
        }
    }

    private func sourceColor(for source: SessionSource) -> Color {
        switch source {
        case .managed:
            return ClientTheme.accentSecondary
        case .terminalApp:
            return ClientTheme.warning
        case .iTermApp:
            return ClientTheme.accent
        }
    }

    private func settingToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClientTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ClientTheme.textSecondary)
                .lineLimit(2)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(ClientTheme.accent)
        }
        .padding(12)
        .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func overviewPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ClientTheme.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ClientTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [ClientTheme.surfaceRaised, tint.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClientTheme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ClientTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func card<Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ClientTheme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(ClientTheme.textSecondary)
                    }
                }
            }

            content()
        }
        .padding(12)
        .background(ClientTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private func primaryButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClientTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(ClientTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ClientTheme.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func footerActionButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func footerSecondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ClientTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(ClientTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ClientTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private struct DashboardMetrics {
        let width: CGFloat
        let dynamicTypeSize: DynamicTypeSize

        var horizontalPadding: CGFloat {
            width >= 430 ? 18 : 16
        }

        var sectionSpacing: CGFloat {
            dynamicTypeSize >= .xxLarge ? 10 : 12
        }

        var headerTopPadding: CGFloat {
            width >= 430 ? 12 : 8
        }

        var bottomDockBottomPadding: CGFloat {
            width >= 430 ? 10 : 8
        }

        var bottomInsetPadding: CGFloat {
            prefersStackedActions ? 144 : 94
        }

        var prefersStackedActions: Bool {
            width < 390
        }
    }
}

private struct RenameSessionSheet: View {
    let session: SessionSummary?
    @Binding var draft: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename \(session?.title ?? "Session")")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClientTheme.textPrimary)

                TextField("Session title", text: $draft)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ClientTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ClientTheme.border, lineWidth: 1)
                    }

                Text("Choose a short, recognizable label for this managed session.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ClientTheme.textSecondary)

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ClientTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}
