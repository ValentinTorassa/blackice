// swift-tools-version: 6.0
// Builds with the Command Line Tools alone; tests use Swift Testing, which ships with them.
import PackageDescription

// NetworkExtension, SystemExtensions, LocalAuthentication and NSXPCConnection predate Swift
// concurrency annotations; the targets that call them use the Swift 5 language mode.
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
        // the hook runner, the event log, the daemon, the provider configuration, the filter's
        // decision, ask mode's state (pending events, tokens, approvals), the host/address check
        // and the XPC messages.
        .target(name: "NetshieldCore"),
        // Argument parsing and the commands, kept out of main.swift so tests can drive them.
        .target(name: "NetshieldCLI", dependencies: ["NetshieldCore"]),
        // The NSXPC protocols and connections between the extension, the daemon and the CLI.
        // The messages they carry, and their checks, are in NetshieldCore.
        .target(name: "NetshieldXPC", dependencies: ["NetshieldCore"], swiftSettings: systemSettings),
        // The commands against macOS: extension activation, the filter preference, Touch ID,
        // and pending/approve/deny/daemon over XPC. Needs the signed app to do anything.
        .target(name: "NetshieldSystem", dependencies: ["NetshieldCore", "NetshieldCLI", "NetshieldXPC"],
                swiftSettings: systemSettings),
        .executableTarget(name: "netshield", dependencies: ["NetshieldCLI", "NetshieldSystem"]),
        // The NEFilterDataProvider system extension.
        .executableTarget(name: "NetshieldFilter", dependencies: ["NetshieldCore", "NetshieldXPC"],
                          swiftSettings: systemSettings),
        .testTarget(name: "NetshieldTests", dependencies: ["NetshieldCore", "NetshieldCLI"]),
    ]
)
