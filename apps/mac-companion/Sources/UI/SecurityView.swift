import SwiftUI
import APTerminalProtocol
import APTerminalSecurity

struct SecurityView: View {
    @ObservedObject var model: MacCompanionAppModel
    @State private var explicitInternetHostDraft: String = ""
    @State private var pendingEnableRemotePreviews = false
    @State private var isAuditLogExpanded = false
    @State private var hasLoadedAuditEvents = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.hasLegacyDemoHostWarning {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.legacyDemoHostWarningSummary, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("Legacy CLI demo hosts can confuse pairing and session discovery. Stop them and use MacCompanion.app as the single host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(model.legacyDemoHostProcesses) { process in
                            Text("\(process.pid)  \(process.command)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Stop Demo Hosts", role: .destructive) {
                                model.stopLegacyDemoHosts()
                            }

                            Button("Refresh Warning State") {
                                Task {
                                    await model.refresh()
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection Mode").font(.headline)
                    Picker(
                        "Connection Mode",
                        selection: Binding(
                            get: { model.connectionMode },
                            set: { newValue in
                                Task {
                                    await model.setConnectionMode(newValue)
                                }
                            }
                        )
                    ) {
                        ForEach(HostConnectionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        model.connectionMode == .lan
                            ? "Local Network keeps pairing payloads on your private Wi-Fi."
                            : "Private Internet uses a Tailscale-reachable endpoint and keeps the listener off the public internet."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if model.connectionMode == .internetVPN {
                        TextField("Optional explicit internet endpoint", text: $explicitInternetHostDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Save Endpoint") {
                                Task {
                                    await model.setExplicitInternetHost(explicitInternetHostDraft)
                                }
                            }

                            Text("Leave blank to prefer a detected Tailscale or `utun` address.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let blockingSummary = model.exposureBlockingSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Host Startup Blocked", systemImage: "xmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(blockingSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if let warningSummary = model.exposureWarningSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Exposure Warning", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(warningSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let primaryAddress = model.localNetworkAddresses.first {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reachable Addresses").font(.headline)
                        HStack {
                            Text(primaryAddress.address)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(primaryAddress.interfaceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.localNetworkAddresses.count > 1 {
                            DisclosureGroup("Fallback Addresses") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(model.localNetworkAddresses.dropFirst()), id: \.address) { address in
                                        HStack {
                                            Text(address.address)
                                                .font(.system(.caption, design: .monospaced))
                                            Spacer()
                                            Text(address.interfaceName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(.caption)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Host Status").font(.headline)
                    HStack {
                        Label(model.hostStatusSummary, systemImage: model.isHostRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .foregroundStyle(model.isHostRunning ? .green : .secondary)
                        Spacer()
                    }
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Label(model.connectionMode.displayName, systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(model.selectedBootstrapEndpointSummary, systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(model.trustedDeviceStatusSummary, systemImage: "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(model.previewPrivilegeSummary, systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(model.previewSubsystemStatusSummary, systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Remote Preview Policy").font(.headline)
                    Toggle(
                        "Allow Existing Terminal/iTerm Previews",
                        isOn: Binding(
                            get: { model.allowExternalTerminalPreviews },
                            set: { isEnabled in
                                if isEnabled && model.connectionMode == .internetVPN {
                                    pendingEnableRemotePreviews = true
                                } else {
                                    Task {
                                        await model.setExternalTerminalPreviewsEnabled(isEnabled)
                                    }
                                }
                            }
                        )
                    )

                    Text(
                        model.connectionMode == .internetVPN
                            ? "Internet mode disables external previews by default because they can expose broad host context."
                            : "LAN mode can expose existing Terminal and iTerm windows as read-only previews."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Allow Managed Session Content Previews",
                        isOn: Binding(
                            get: { model.allowManagedSessionContentPreviews },
                            set: { isEnabled in
                                Task {
                                    await model.setManagedSessionContentPreviewsEnabled(isEnabled)
                                }
                            }
                        )
                    )

                    Text("Managed session previews use the same per-device preview privilege as external Terminal or iTerm windows. Devices without preview privilege still see session metadata, but not content excerpts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Grant preview access per device in Devices. That local Mac approval is what allows full-fidelity preview content to leave the Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Pairing Bootstrap Payload").font(.headline)

                if let qrImage = model.pairingQRCodeImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing QR").font(.headline)
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 320, height: 320)
                            .padding(16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            }

                        Text("Scan this code from the iPhone app. If scanning is unreliable, use Copy Pairing Payload below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let pairingTokenExpiresAt = model.pairingTokenExpiresAt {
                            Text("Expires \(pairingTokenExpiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SelectablePayloadBlock(text: model.pairingPayloadJSONString)
                    .frame(minHeight: 240, maxHeight: 320)
                HStack {
                    Button("Generate New Pairing Payload") {
                        Task {
                            await model.regeneratePairingPayload()
                        }
                    }
                    .disabled(model.isHostRunning == false)

                    Button("Copy Pairing Payload") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.pairingPayloadJSONString, forType: .string)
                    }
                    .disabled(model.pairingPayloadJSONString.isEmpty)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("Audit Log", isExpanded: $isAuditLogExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("The audit log contains trust and session security events only. Terminal transcript content is excluded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text(model.auditLogPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }

                            HStack {
                                Button("Refresh Audit Log") {
                                    Task {
                                        await model.refreshAuditEvents()
                                        hasLoadedAuditEvents = true
                                    }
                                }
                                Button("Copy Log Path") {
                                    model.copyAuditLogPath()
                                }
                            }

                            if model.auditEvents.isEmpty {
                                Text(hasLoadedAuditEvents ? "No audit events recorded yet." : "Expand this section and refresh to load recent audit events.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(model.auditEvents.enumerated()), id: \.offset) { _, event in
                                        AuditEventRow(event: event)
                                        Divider()
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.headline)
                }
            }
            .padding()
        }
        .navigationTitle("Security")
        .onAppear {
            explicitInternetHostDraft = model.explicitInternetHost
        }
        .task(id: isAuditLogExpanded) {
            guard isAuditLogExpanded, hasLoadedAuditEvents == false else {
                return
            }

            await model.refreshAuditEvents()
            hasLoadedAuditEvents = true
        }
        .alert("Enable Remote External Previews?", isPresented: $pendingEnableRemotePreviews) {
            Button("Enable", role: .destructive) {
                Task {
                    await model.setExternalTerminalPreviewsEnabled(true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing Terminal and iTerm windows can reveal broad host context. Keep this off unless you explicitly want those previews available over Tailscale.")
        }
    }
}

private struct SelectablePayloadBlock: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No pairing payload available." : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AuditEventRow: View {
    let event: AuditEventRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.kind.displayName)
                    .font(.headline)
                Spacer()
                Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let deviceID = event.deviceID?.rawValue {
                Label(deviceID, systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sessionID = event.sessionID?.rawValue {
                Label(sessionID, systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = event.note, note.isEmpty == false {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension AuditEventKind {
    var displayName: String {
        switch self {
        case .devicePaired:
            return "Device Paired"
        case .deviceRevoked:
            return "Device Revoked"
        case .previewAccessGranted:
            return "Preview Access Granted"
        case .previewAccessRevoked:
            return "Preview Access Revoked"
        case .previewAccessDenied:
            return "Preview Access Denied"
        case .previewAccessUsed:
            return "Preview Access Used"
        case .connectionAccepted:
            return "Connection Accepted"
        case .connectionDenied:
            return "Connection Denied"
        case .authChallengeIssued:
            return "Auth Challenge Issued"
        case .authProofAccepted:
            return "Auth Proof Accepted"
        case .authProofRejected:
            return "Auth Proof Rejected"
        case .sessionAttached:
            return "Session Attached"
        case .sessionDetached:
            return "Session Detached"
        case .remoteSessionCreated:
            return "Remote Session Created"
        case .externalPreviewsEnabled:
            return "External Previews Enabled"
        case .externalPreviewsDisabled:
            return "External Previews Disabled"
        case .externalPreviewAttached:
            return "External Preview Attached"
        }
    }
}
