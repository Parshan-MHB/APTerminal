import Foundation
import APTerminalClient
import APTerminalProtocol
import APTerminalSecurity

@main
struct APTerminalClientDemoApp {
    static func main() async {
        let arguments = CommandLine.arguments

        guard arguments.count >= 2 else {
            fputs("Usage: apterminal-client-demo <bootstrap-json> | <host> <port> <pairing-token>\n", stderr)
            return
        }

        let bootstrap: PairingBootstrapPayload?
        let host: String
        let port: UInt16
        let pairingTokenValue: String

        if arguments.count == 2, let data = arguments[1].data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decodedBootstrap = try? decoder.decode(PairingBootstrapPayload.self, from: data) else {
                fputs("Invalid bootstrap JSON\n", stderr)
                return
            }
            bootstrap = decodedBootstrap
            host = decodedBootstrap.host
            port = decodedBootstrap.port
            pairingTokenValue = decodedBootstrap.token.value
        } else if arguments.count >= 4 {
            bootstrap = nil
            host = arguments[1]
            guard let parsedPort = UInt16(arguments[2]) else {
                fputs("Invalid port\n", stderr)
                return
            }
            port = parsedPort
            pairingTokenValue = arguments[3]
        } else {
            fputs("Usage: apterminal-client-demo <bootstrap-json> | <host> <port> <pairing-token>\n", stderr)
            return
        }

        let client = ConnectionManager(
            deviceIdentity: DeviceIdentity(
                id: .random(),
                name: Host.current().localizedName ?? "iPhone Demo",
                platform: .iOS,
                appVersion: APTerminalAppMetadata.currentAppVersion()
            ),
            trustedHostRegistry: TrustedHostRegistry(store: InMemoryTrustedHostStore())
        )

        await client.setTerminalOutputHandler { chunk in
            let output = String(decoding: chunk.data, as: UTF8.self)
            print("OUTPUT[\(chunk.sessionID.rawValue.prefix(8))]: \(output)", terminator: "")
        }

        do {
            let hello: HelloMessage
            if let bootstrap {
                hello = try await client.connect(using: bootstrap)
            } else {
                hello = try await client.connect(host: host, port: port)
            }
            print("Connected to \(hello.device.name)")

            let pairResponse = try await client.pair(
                using: PairingToken(
                    value: pairingTokenValue,
                    expiresAt: Date().addingTimeInterval(APTerminalConfiguration.defaultPairingTokenLifetime)
                )
            )

            print("Pair response: \(pairResponse.status.rawValue)")

            let sessions = try await client.listSessions()
            print("Sessions: \(sessions.map(\.title))")

            if let firstSession = sessions.first {
                _ = try await client.attachSession(id: firstSession.id)
                try await client.sendInput(sessionID: firstSession.id, data: Data("echo apterminal-smoke\n".utf8))
                try await Task.sleep(for: .seconds(1))
            }

            await client.disconnect()
        } catch {
            fputs("Client demo failed: \(error)\n", stderr)
        }
    }
}
