import SwiftUI

@main
struct iOSClientApp: App {
    @StateObject private var model = iOSClientAppModel()
    @StateObject private var appLockManager = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionsListView(model: model)
            }
            .task {
                _ = await appLockManager.unlock()
            }
            .overlay {
                if appLockManager.isUnlocked == false {
                    ZStack {
                        ClientTheme.backgroundTop
                            .ignoresSafeArea()

                        VStack(spacing: 16) {
                            Text("APTerminal")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(ClientTheme.textPrimary)
                            Text("Unlock to view trusted Macs and interact with your sessions.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(ClientTheme.textSecondary)
                            Button("Unlock") {
                                Task {
                                    _ = await appLockManager.unlock()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ClientTheme.accentSecondary)
                        }
                        .padding(32)
                        .background(ClientTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(ClientTheme.border, lineWidth: 1)
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .environmentObject(appLockManager)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                model.sceneDidEnterBackground()
                appLockManager.lock()
            case .active:
                appLockManager.relockIfNeeded()
                model.sceneDidBecomeActive()
            @unknown default:
                model.sceneDidEnterBackground()
                appLockManager.lock()
            }
        }
    }
}
