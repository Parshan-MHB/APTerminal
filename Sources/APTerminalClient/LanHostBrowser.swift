import Foundation
import Network
import APTerminalTransport

public struct DiscoveredHost: Equatable, Sendable {
    public var endpointDescription: String

    public init(endpointDescription: String) {
        self.endpointDescription = endpointDescription
    }
}

public final class LanHostBrowser: @unchecked Sendable {
    public var onResultsChanged: (@Sendable ([DiscoveredHost]) -> Void)?

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "com.apterminal.browser")

    public init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjour(type: BonjourConstants.serviceType, domain: nil), using: parameters)
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.map { result in
                DiscoveredHost(endpointDescription: "\(result.endpoint)")
            }.sorted { $0.endpointDescription < $1.endpointDescription }

            self?.onResultsChanged?(hosts)
        }

        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
    }
}
