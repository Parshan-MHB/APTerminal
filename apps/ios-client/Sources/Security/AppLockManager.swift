import Foundation
import LocalAuthentication
import APTerminalProtocol

struct IdleLockOption: Identifiable, Hashable {
    let seconds: TimeInterval
    let title: String

    var id: TimeInterval { seconds }
}

@MainActor
final class AppLockManager: ObservableObject {
    static let idleTimeoutOptions: [IdleLockOption] = [
        .init(seconds: 60, title: "1 minute"),
        .init(seconds: 120, title: "2 minutes"),
        .init(seconds: 300, title: "5 minutes"),
        .init(seconds: 900, title: "15 minutes"),
        .init(seconds: 1800, title: "30 minutes"),
    ]

    @Published private(set) var isUnlocked = false
    @Published var idleTimeout: TimeInterval = APTerminalConfiguration.defaultIdleLockTimeoutSeconds

    private let userDefaults: UserDefaults
    private var lastUnlockAt: Date?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let storedTimeout = userDefaults.object(forKey: Self.idleTimeoutDefaultsKey) as? Double {
            idleTimeout = storedTimeout
        }
#if targetEnvironment(simulator)
        isUnlocked = true
#endif
    }

    func lock() {
#if targetEnvironment(simulator)
        return
#else
        isUnlocked = false
#endif
    }

    func markActivity() {
        guard isUnlocked else { return }
        lastUnlockAt = Date()
    }

    func relockIfNeeded() {
#if targetEnvironment(simulator)
        return
#else
        guard let lastUnlockAt else { return }
        if Date().timeIntervalSince(lastUnlockAt) >= idleTimeout {
            isUnlocked = false
        }
#endif
    }

    func updateIdleTimeout(_ timeout: TimeInterval) {
        idleTimeout = timeout
        userDefaults.set(timeout, forKey: Self.idleTimeoutDefaultsKey)
        relockIfNeeded()
    }

    func unlock() async -> Bool {
#if targetEnvironment(simulator)
        isUnlocked = true
        lastUnlockAt = Date()
        return true
#else
        relockIfNeeded()

        if isUnlocked {
            markActivity()
            return true
        }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = false
            return false
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock APTerminal")
            isUnlocked = success
            if success {
                lastUnlockAt = Date()
            }
            return success
        } catch {
            isUnlocked = false
            return false
        }
#endif
    }

    private static let idleTimeoutDefaultsKey = "security.idleTimeoutSeconds"
}
