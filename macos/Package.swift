// swift-tools-version: 6.0
// Builds with the Command Line Tools alone; tests use Swift Testing, which ships with them.
import PackageDescription

let package = Package(
    name: "netshield",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "netshield", targets: ["netshield"]),
    ],
    targets: [
        // Code identity, host names, the TLS server name reader, netshield.toml, hook events,
        // the hook runner, the event log and the daemon.
        .target(name: "NetshieldCore"),
        // Argument parsing and the commands, kept out of main.swift so tests can drive them.
        .target(name: "NetshieldCLI", dependencies: ["NetshieldCore"]),
        .executableTarget(name: "netshield", dependencies: ["NetshieldCLI"]),
        .testTarget(name: "NetshieldTests", dependencies: ["NetshieldCore", "NetshieldCLI"]),
    ]
)
