// swift-tools-version: 6.0
// Builds with the Command Line Tools alone; tests use Swift Testing, which ships with them.
import PackageDescription

// NetworkExtension, SystemExtensions, LocalAuthentication, ServiceManagement and NSXPCConnection
// predate Swift concurrency annotations; the targets that call them use the Swift 5 language mode.
let systemSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "blackice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "blackice", targets: ["blackice"]),
        // The system extension's executable; scripts/build-app.sh puts it inside Blackice.app.
        .executable(name: "blackice-filter", targets: ["BlackiceFilter"]),
    ],
    targets: [
        // Code identity, host names, the TLS server name reader, blackice.toml, hook events,
        // the hook runner, the event log, the daemon, the provider configuration, the filter's
        // decision, ask mode's state (pending events, tokens, approvals), the host/address check
        // and the XPC messages.
        .target(name: "BlackiceCore"),
        // Argument parsing and the commands, kept out of main.swift so tests can drive them.
        .target(name: "BlackiceCLI", dependencies: ["BlackiceCore"]),
        // The NSXPC protocols and connections between the extension, the daemon and the CLI.
        // The messages they carry, and their checks, are in BlackiceCore.
        .target(name: "BlackiceXPC", dependencies: ["BlackiceCore"], swiftSettings: systemSettings),
        // The commands against macOS: extension activation, the filter preference, Touch ID,
        // and pending/approve/deny/daemon over XPC. Needs the signed app to do anything.
        .target(name: "BlackiceSystem", dependencies: ["BlackiceCore", "BlackiceCLI", "BlackiceXPC"],
                swiftSettings: systemSettings),
        // The menu bar app: `blackice menu`, and Blackice.app opened from Finder or at login. What
        // it shows is worked out in plain Swift; SystemAdapter.swift is its one way into status,
        // pending, mode, approve and deny.
        .target(name: "BlackiceMenu", dependencies: ["BlackiceCore", "BlackiceCLI", "BlackiceXPC", "BlackiceSystem"],
                swiftSettings: systemSettings),
        .executableTarget(name: "blackice", dependencies: ["BlackiceCLI", "BlackiceSystem", "BlackiceMenu"]),
        // The NEFilterDataProvider system extension.
        .executableTarget(name: "BlackiceFilter", dependencies: ["BlackiceCore", "BlackiceXPC"],
                          swiftSettings: systemSettings),
        .testTarget(name: "BlackiceTests", dependencies: ["BlackiceCore", "BlackiceCLI", "BlackiceMenu"]),
    ]
)
