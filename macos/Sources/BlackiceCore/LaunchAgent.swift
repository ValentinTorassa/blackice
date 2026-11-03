import Darwin
import Foundation

// The daemon's LaunchAgent. `blackice agent install` writes
// ~/Library/LaunchAgents/com.valentorassa.blackice.daemon.plist, naming the blackice binary
// inside Blackice.app, and loads it with `launchctl bootstrap gui/<uid>`; `blackice agent
// uninstall` boots it out and removes the file. Neither asks for Touch ID: the agent is the
// user's own, and the daemon takes its hooks from the configuration the extension holds, so a
// second copy of it gains nothing. macos/LaunchAgent/ has the same plist with placeholders, and
// a test keeps the two in step.

public struct LaunchAgentError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// What a launchctl run printed and how it exited.
public struct LaunchctlResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public enum LaunchAgent {
    public static let label = "com.valentorassa.blackice.daemon"
    /// launchd waits this long before starting the daemon again after it exits.
    public static let throttleSeconds = 10
    public static let launchctl = "/bin/launchctl"
    /// launchctl bootout's statuses for a service that is not loaded: ESRCH, and 113 ("Could not
    /// find service").
    public static let notLoadedStatuses: Set<Int32> = [3, 113]

    public static func plistURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).appendingPathComponent(label + ".plist")
    }

    /// The plist for `binary`, the blackice executable inside Blackice.app, with launchd's copies of
    /// the daemon's stdout and stderr in `logDirectory`. Both must be absolute paths. The daemon
    /// gets no arguments beyond `daemon` and no environment from the plist.
    public static func plist(binary: String, logDirectory: String) throws -> Data {
        for path in [binary, logDirectory] {
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw LaunchAgentError("\(path) is not an absolute path")
            }
        }
        let directory = logDirectory.hasSuffix("/") ? String(logDirectory.dropLast()) : logDirectory
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "daemon"],
            "RunAtLoad": true,
            // Started again when it exits with an error: status 75 when the connection to the
            // extension ends, so that it registers anew.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": throttleSeconds,
            "ProcessType": "Standard",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": directory + "/daemon.out.log",
            "StandardErrorPath": directory + "/daemon.err.log",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// Accepts only `…/Blackice.app/Contents/MacOS/blackice` as an absolute path with no `.`, `..`
    /// or empty components; resolve symlinks first. Returns the path unchanged.
    public static func checkBundledBinary(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.hasPrefix("/"), components.count >= 5,
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              Array(components.suffix(4)) == ["Blackice.app", "Contents", "MacOS", "blackice"] else {
            throw LaunchAgentError("this blackice is not inside Blackice.app (it is \(path)); run the one in Blackice.app, " +
                                   "for example /Applications/Blackice.app/Contents/MacOS/blackice agent install")
        }
        return path
    }

    /// The running executable's path with symlinks resolved, or nil.
    public static func runningBinary() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(validatingCString: real)
    }

    /// Runs /bin/launchctl with `arguments` and collects what it prints. Kept thin on purpose: the
    /// decisions are in LaunchAgentInstaller, which tests drive with a fake.
    public static func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchctl)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return LaunchctlResult(status: 127, output: "cannot run \(launchctl): \(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(status: process.terminationStatus,
                               output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Installs and removes the daemon's LaunchAgent for one user. `launchctl` runs /bin/launchctl in
/// the real CLI (`LaunchAgent.run`) and a recorder in tests.
public struct LaunchAgentInstaller {
    public let account: UserAccount
    public let launchctl: ([String]) -> LaunchctlResult

    public init(account: UserAccount, launchctl: @escaping ([String]) -> LaunchctlResult) {
        self.account = account
        self.launchctl = launchctl
    }

    public var domain: String { "gui/\(account.uid)" }
    public var service: String { "\(domain)/\(LaunchAgent.label)" }
    public var plistURL: URL { LaunchAgent.plistURL(home: account.homeURL) }
    public var logDirectory: URL { DaemonPaths.logDirectory(home: account.homeURL) }

    /// Writes the plist for `binary` (which must be inside Blackice.app) and loads it. The log
    /// directory is created with mode 0700 first, since launchd opens the stderr file before the
    /// daemon runs. A copy already loaded is booted out first, so installing again after moving
    /// Blackice.app picks up the new path.
    public func install(binary: String, say: (String) -> Void) throws {
        let binary = try LaunchAgent.checkBundledBinary(binary)
        let data = try LaunchAgent.plist(binary: binary, logDirectory: logDirectory.path)
        try FileManager.default.createDirectory(at: logDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateDirectory.ensure(logDirectory)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        guard chmod(plistURL.path, 0o644) == 0 else {
            throw FileSafetyError(plistURL.path, "cannot set mode 0644: \(errnoText(errno))")
        }
        // Not loaded is the usual case here, and fine; anything else shows up in bootstrap.
        _ = launchctl(["bootout", service])
        let loaded = launchctl(["bootstrap", domain, plistURL.path])
        guard loaded.status == 0 else {
            throw LaunchAgentError("launchctl bootstrap \(domain) failed with status \(loaded.status)" +
                                   (loaded.output.isEmpty ? "" : ": \(loaded.output)"))
        }
        say("✓ The daemon is running, and starts again at each login. It runs your hooks for connections that wait.")
        say("  Its logs are in \(Describe.path(logDirectory.path, home: account.homeURL.path)).")
    }

    /// Boots the agent out and removes its plist. When bootout fails for a reason other than the
    /// agent not being loaded, the plist stays, so that the command can be run again.
    public func uninstall(say: (String) -> Void) throws {
        let result = launchctl(["bootout", service])
        if result.status == 0 {
            say("✓ The daemon is stopped.")
        } else if LaunchAgent.notLoadedStatuses.contains(result.status) {
            say("The daemon was not running.")
        } else {
            throw LaunchAgentError("launchctl bootout \(service) failed with status \(result.status)" +
                                   (result.output.isEmpty ? "" : ": \(result.output)") + "; \(plistURL.path) was left in place")
        }
        if unlink(plistURL.path) == 0 {
            say("✓ Removed its LaunchAgent; it no longer starts at login.")
        } else if errno == ENOENT {
            say("There was no LaunchAgent to remove.")
        } else {
            throw FileSafetyError(plistURL.path, "cannot remove it: \(errnoText(errno))")
        }
    }
}
