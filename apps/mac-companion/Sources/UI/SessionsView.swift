import SwiftUI
import APTerminalProtocol

struct SessionsView: View {
    @ObservedObject var model: MacCompanionAppModel

    var body: some View {
        List {
            if model.hasLegacyDemoHostWarning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.legacyDemoHostWarningSummary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

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
                    .padding(.vertical, 4)
                }
            }

            Section {
                HStack {
                    Label(model.hostStatusSummary, systemImage: model.isHostRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(model.isHostRunning ? .green : .secondary)
                    Spacer()
                    if let hostPort = model.hostPort, model.isHostRunning {
                        Text("Port \(hostPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Sessions") {
                ForEach(model.sessions, id: \.id) { session in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(session.title).font(.headline)
                                sessionBadge(title: sourceTitle(for: session), color: sourceColor(for: session))
                                sessionBadge(title: session.state.rawValue.capitalized, color: stateColor(for: session.state))
                            }
                            Text(session.workingDirectory).font(.caption).foregroundStyle(.secondary)
                            if session.isManaged, session.previewExcerpt.isEmpty == false {
                                Text(session.previewExcerpt)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(3)
                            }
                        }

                        Spacer()

                        if session.capabilities.supportsClose {
                            Button(model.closingSessionIDs.contains(session.id) ? "Closing..." : "Close", role: .destructive) {
                                Task {
                                    await model.closeSession(session.id)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.closingSessionIDs.contains(session.id))
                        } else {
                            Text("Preview")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            Button(model.isHostRunning ? "Stop Host" : "Start Host") {
                Task {
                    await model.toggleHost()
                }
            }

            Button("New Session") {
                Task {
                    await model.createSession()
                }
            }
            .disabled(model.isHostRunning == false)

            Button("Refresh") {
                Task {
                    await model.refresh()
                }
            }
        }
        .navigationTitle("Sessions")
    }

    private func sessionBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func sourceTitle(for session: SessionSummary) -> String {
        switch session.source {
        case .managed:
            return "Managed"
        case .terminalApp:
            return "Terminal"
        case .iTermApp:
            return "iTerm"
        }
    }

    private func sourceColor(for session: SessionSummary) -> Color {
        switch session.source {
        case .managed:
            return .blue
        case .terminalApp:
            return .orange
        case .iTermApp:
            return .green
        }
    }

    private func stateColor(for state: SessionState) -> Color {
        switch state {
        case .starting:
            return .blue
        case .running:
            return .green
        case .attached:
            return .purple
        case .closing:
            return .orange
        case .exited:
            return .secondary
        case .failed:
            return .red
        }
    }
}
