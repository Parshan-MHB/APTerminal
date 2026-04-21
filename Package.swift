// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APTerminal",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "APTerminalProtocol",
            targets: ["APTerminalProtocol"]
        ),
        .library(
            name: "APTerminalProtocolCodec",
            targets: ["APTerminalProtocolCodec"]
        ),
        .library(
            name: "APTerminalSecurity",
            targets: ["APTerminalSecurity"]
        ),
        .library(
            name: "APTerminalPTY",
            targets: ["APTerminalPTY"]
        ),
        .library(
            name: "APTerminalCore",
            targets: ["APTerminalCore"]
        ),
        .library(
            name: "APTerminalTransport",
            targets: ["APTerminalTransport"]
        ),
        .library(
            name: "APTerminalHost",
            targets: ["APTerminalHost"]
        ),
        .library(
            name: "APTerminalClient",
            targets: ["APTerminalClient"]
        ),
        .executable(
            name: "apterminal-host-demo",
            targets: ["APTerminalHostDemo"]
        ),
        .executable(
            name: "apterminal-client-demo",
            targets: ["APTerminalClientDemo"]
        ),
    ],
    targets: [
        .target(
            name: "APTerminalProtocol"
        ),
        .target(
            name: "APTerminalProtocolCodec",
            dependencies: ["APTerminalProtocol"]
        ),
        .target(
            name: "APTerminalSecurity",
            dependencies: ["APTerminalProtocol"]
        ),
        .target(
            name: "APTerminalPTY"
        ),
        .target(
            name: "APTerminalCore",
            dependencies: ["APTerminalProtocol", "APTerminalPTY"]
        ),
        .target(
            name: "APTerminalTransport",
            dependencies: ["APTerminalProtocol", "APTerminalProtocolCodec"]
        ),
        .target(
            name: "APTerminalHost",
            dependencies: [
                "APTerminalCore",
                "APTerminalProtocol",
                "APTerminalProtocolCodec",
                "APTerminalSecurity",
                "APTerminalTransport",
            ]
        ),
        .target(
            name: "APTerminalClient",
            dependencies: [
                "APTerminalProtocol",
                "APTerminalProtocolCodec",
                "APTerminalSecurity",
                "APTerminalTransport",
            ]
        ),
        .executableTarget(
            name: "APTerminalHostDemo",
            dependencies: ["APTerminalHost", "APTerminalCore", "APTerminalSecurity"]
        ),
        .executableTarget(
            name: "APTerminalClientDemo",
            dependencies: ["APTerminalClient", "APTerminalProtocol"]
        ),
        .testTarget(
            name: "APTerminalProtocolTests",
            dependencies: ["APTerminalProtocol"]
        ),
        .testTarget(
            name: "APTerminalCoreTests",
            dependencies: ["APTerminalCore", "APTerminalProtocol"]
        ),
        .testTarget(
            name: "APTerminalClientTests",
            dependencies: ["APTerminalClient", "APTerminalProtocol"]
        ),
        .testTarget(
            name: "APTerminalTransportTests",
            dependencies: ["APTerminalProtocol", "APTerminalTransport"]
        ),
        .testTarget(
            name: "APTerminalPTYTests",
            dependencies: ["APTerminalPTY"]
        ),
        .testTarget(
            name: "APTerminalProtocolCodecTests",
            dependencies: ["APTerminalProtocol", "APTerminalProtocolCodec"]
        ),
        .testTarget(
            name: "APTerminalSecurityTests",
            dependencies: ["APTerminalProtocol", "APTerminalSecurity"]
        ),
        .testTarget(
            name: "APTerminalIntegrationTests",
            dependencies: [
                "APTerminalClient",
                "APTerminalCore",
                "APTerminalHost",
                "APTerminalProtocol",
                "APTerminalSecurity",
            ]
        ),
    ]
)
