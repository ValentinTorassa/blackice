// swift-tools-version: 6.0
// Builds with the Command Line Tools alone; tests use Swift Testing, which ships with them.
import PackageDescription

// NetworkExtension, SystemExtensions and LocalAuthentication predate Swift concurrency
// annotations; the targets that call them use the Swift 5 language mode.
let systemSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "netshield",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "netshield", targets: ["netshield"]),
        // The system extension's executable; scripts/build-app.sh puts it inside Netshield.app.
        .executable(name: "netshield-filter", targets: ["NetshieldFilter"]),
    ],
    targets: [
        // Code identity, host names, the TLS server name reader, netshield.toml, hook events,
        // the hook runner, the event log, the daemon, the provider configuration and the
        // filter's decision.
        .target(name: "NetshieldCore"),
        // Argument parsing and the commands, kept out of main.swift so tests can drive them.
        .target(name: "NetshieldCLI", dependencies: ["NetshieldCore"]),
        // start, stop, status and mode against macOS: extension activation, the filter
        // preference and Touch ID. Needs the signed app to do anything.
        .target(name: "NetshieldSystem", dependencies: ["NetshieldCore", "NetshieldCLI"],
                swiftSettings: systemSettings),
        .executableTarget(name: "netshield", dependencies: ["NetshieldCLI", "NetshieldSystem"]),
        // The NEFilterDataProvider system extension.
        .executableTarget(name: "NetshieldFilter", dependencies: ["NetshieldCore"], swiftSettings: systemSettings),
        .testTarget(name: "NetshieldTests", dependencies: ["NetshieldCore", "NetshieldCLI"]),
    ]
)
