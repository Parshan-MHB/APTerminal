import Foundation
import Network
import APTerminalProtocol

enum LocalNetworkAuthorizationError: LocalizedError {
    case denied(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .denied(message):
            return message
        case .timedOut:
            return "Local network permission did not complete in time."
        }
    }
}

@MainActor
final class LocalNetworkAuthorizer {
    private enum AuthorizationState {
        case unknown
        case granted
        case denied(String)
    }

    private static let permissionServiceType = "_tcompauth._tcp"

    private var state: AuthorizationState = .unknown
    private var activeRequest: Task<Bool, Error>?

    func requestAccess(forceRetry: Bool = false) async throws -> Bool {
        if forceRetry {
            state = .unknown
        }

        switch state {
        case .granted:
            return true
        case let .denied(message):
            throw LocalNetworkAuthorizationError.denied(message)
        case .unknown:
            break
        }

        if let activeRequest {
            return try await activeRequest.value
        }

        let task = Task<Bool, Error> {
            defer { Task { @MainActor in self.activeRequest = nil } }
            return try await performAuthorizationRequest()
        }
        activeRequest = task
        return try await task.value
    }

    private func performAuthorizationRequest() async throws -> Bool {
#if targetEnvironment(simulator)
        state = .granted
        return true
#else
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false

        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: UUID().uuidString, type: Self.permissionServiceType)
        listener.newConnectionHandler = { connection in
            connection.cancel()
        }

        let browser = NWBrowser(
            for: .bonjour(type: Self.permissionServiceType, domain: nil),
            using: parameters
        )

        let queue = DispatchQueue(label: "com.apterminal.local-network-auth")

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let requestState = AuthorizationRequestState(
                        listener: listener,
                        browser: browser,
                        continuation: continuation
                    )

                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error):
                            requestState.finish(.failure(LocalNetworkAuthorizationError.denied(error.localizedDescription)))
                        default:
                            break
                        }
                    }

                    browser.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            requestState.finish(.success(true))
                        case .waiting(let error), .failed(let error):
                            requestState.finish(.failure(LocalNetworkAuthorizationError.denied(error.localizedDescription)))
                        default:
                            break
                        }
                    }

                    browser.browseResultsChangedHandler = { results, _ in
                        if results.isEmpty == false {
                            requestState.finish(.success(true))
                        }
                    }

                    listener.start(queue: queue)
                    browser.start(queue: queue)
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(APTerminalConfiguration.defaultLocalNetworkAuthorizationTimeoutSeconds))
                throw LocalNetworkAuthorizationError.timedOut
            }

            do {
                let result = try await group.next() ?? false
                group.cancelAll()
                state = .granted
                return result
            } catch {
                group.cancelAll()
                let message = (error as? LocalNetworkAuthorizationError)?.localizedDescription ?? error.localizedDescription
                state = .denied(message)
                throw error
            }
        }
#endif
    }
}

private final class AuthorizationRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: NWListener
    private let browser: NWBrowser
    private var continuation: CheckedContinuation<Bool, Error>?

    init(
        listener: NWListener,
        browser: NWBrowser,
        continuation: CheckedContinuation<Bool, Error>
    ) {
        self.listener = listener
        self.browser = browser
        self.continuation = continuation
    }

    func finish(_ result: Result<Bool, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        browser.cancel()
        listener.cancel()
        continuation.resume(with: result)
    }
}
