import AppKit
import SwiftUI

@main
struct MacCompanionApp: App {
    private enum SidebarItem: String, CaseIterable, Hashable {
        case sessions
        case devices
        case security

        var title: String {
            switch self {
            case .sessions:
                return "Sessions"
            case .devices:
                return "Devices"
            case .security:
                return "Security"
            }
        }
    }

    @StateObject private var model = MacCompanionAppModel()
    @State private var selectedSidebarItem: SidebarItem? = .sessions

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                List(SidebarItem.allCases, id: \.self, selection: $selectedSidebarItem) { item in
                    Text(item.title)
                        .tag(item)
                }
            } detail: {
                detailView(for: selectedSidebarItem ?? .sessions)
            }
            .frame(minWidth: 1000, minHeight: 700)
            .task {
                await model.boot()
            }
        }

        MenuBarExtra("APTerminal", systemImage: model.isHostRunning ? "terminal.fill" : "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                if model.hasLegacyDemoHostWarning {
                    Label(model.legacyDemoHostWarningSummary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Button("Stop Demo Hosts", role: .destructive) {
                        model.stopLegacyDemoHosts()
                    }

                    Divider()
                }

                Label(model.hostStatusSummary, systemImage: model.isHostRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(model.isHostRunning ? .green : .secondary)

                if let hostPort = model.hostPort, model.isHostRunning {
                    Text("Port \(hostPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(model.isHostRunning ? "Stop Host" : "Start Host") {
                    Task {
                        await model.toggleHost()
                    }
                }

                Button("Refresh") {
                    Task {
                        await model.refresh()
                    }
                }

                Divider()

                Button("Show APTerminal") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .sessions:
            SessionsView(model: model)
        case .devices:
            DevicesView(model: model)
        case .security:
            SecurityView(model: model)
        }
    }
}
