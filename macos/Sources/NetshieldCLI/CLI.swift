import Foundation
import NetshieldCore

/// Exit codes follow sysexits(3).
public enum ExitCode {
    public static let success: Int32 = 0
    public static let usage: Int32 = 64       // EX_USAGE
    public static let invalidConfig: Int32 = 65 // EX_DATAERR
    public static let unreadable: Int32 = 66  // EX_NOINPUT
    public static let unavailable: Int32 = 69 // EX_UNAVAILABLE: needs the signed app or the extension
    public static let software: Int32 = 70    // EX_SOFTWARE: a system request failed
    public static let tempFail: Int32 = 75    // EX_TEMPFAIL: the saved configuration changed meanwhile; retry
    public static let noPermission: Int32 = 77 // EX_NOPERM: Touch ID cancelled or failed
}

public enum Command: Equatable, Sendable {
    case help
    case start(configPath: String?)
    case stop, status, pending
    case mode(Mode)
    case approve(Approval)
    case deny(Denial)
    case validate(path: String)
    case daemon(configPath: String)

    public var name: String {
        switch self {
        case .help: return "help"
        case .start: return "start"
        case .stop: return "stop"
        case .status: return "status"
        case .pending: return "pending"
        case .mode: return "mode"
        case .approve: return "approve"
        case .deny: return "deny"
        case .validate: return "validate"
        case .daemon: return "daemon"
        }
    }
}

public struct Approval: Equatable, Sendable {
    public let app: String
    /// nil means Apple platform code.
    public let team: String?
    public let host: String
    public let seconds: Int
    public let token: String?
}

public struct Denial: Equatable, Sendable {
    public let app: String
    public let team: String?
    public let host: String
    public let token: String?
}

public struct UsageError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum CLI {
    public static let defaultApprovalSeconds = 3600
    public static let maximumApprovalSeconds = 86_400

    public static let usage = """
    usage: netshield <command> [options]

    Commands:
      validate PATH                      Check a netshield.toml file
      start [--config PATH]              Activate the extension and start filtering with PATH
                                         (default ~/.config/netshield/netshield.toml)
      stop                               Stop filtering and deactivate the extension
      status                             Mode, rules, approvals and paused connections
      mode accept-all | ask | block-all  Change the mode
      pending                            Connections waiting for an answer
      approve --app ID [--team TEAM] --host HOST [--for 1h] [--token TOKEN]
                                         Let one app reach one host until the approval expires
      deny --app ID [--team TEAM] --host HOST [--token TOKEN]
                                         Drop the waiting connection and the ones like it
      daemon --config PATH               Run the hooks for paused connections (the LaunchAgent)
      help                               Show this help

    validate works anywhere. start, stop, status and mode need Netshield.app signed
    with the Developer ID; any other build says so and exits with status 69. They ask
    for Touch ID before changing filtering. pending, approve, deny and daemon arrive
    with ask mode (phase 2); they check their arguments and exit with status 69.
    Without --team, --app names Apple platform code, which has no Team ID.
    """

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError("missing command") }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "help", "-h", "--help":
            try noArguments(first, rest)
            return .help
        case "start":
            let options = try parseOptions(rest, allowed: ["config"], command: first)
            if let path = options["config"], path.hasPrefix("-") { throw UsageError("start: --config needs a path") }
            return .start(configPath: options["config"])
        case "stop": try noArguments(first, rest); return .stop
        case "status": try noArguments(first, rest); return .status
        case "pending": try noArguments(first, rest); return .pending
        case "mode":
            guard rest.count == 1, let mode = Mode(rawValue: rest[0]) else {
                throw UsageError("mode takes one of accept-all, ask or block-all")
            }
            return .mode(mode)
        case "validate":
            guard rest.count == 1, !rest[0].isEmpty, !rest[0].hasPrefix("-") else {
                throw UsageError("validate takes one path")
            }
            return .validate(path: rest[0])
        case "daemon":
            let options = try parseOptions(rest, allowed: ["config"], command: first)
            guard let path = options["config"], !path.hasPrefix("-") else { throw UsageError("daemon needs --config PATH") }
            return .daemon(configPath: path)
        case "approve":
            let options = try parseOptions(rest, allowed: ["app", "team", "host", "for", "token"], command: first)
            let target = try target(options, command: first)
            var seconds = defaultApprovalSeconds
            if let text = options["for"] {
                guard let parsed = parseDuration(text), parsed <= maximumApprovalSeconds else {
                    throw UsageError("--for takes a duration such as 30s, 10m or 1h, at most 24h")
                }
                seconds = parsed
            }
            return .approve(Approval(app: target.app, team: target.team, host: target.host, seconds: seconds,
                                     token: try token(options)))
        case "deny":
            let options = try parseOptions(rest, allowed: ["app", "team", "host", "token"], command: first)
            let target = try target(options, command: first)
            return .deny(Denial(app: target.app, team: target.team, host: target.host, token: try token(options)))
        default:
            throw UsageError("unknown command '\(printable(first))'")
        }
    }

    /// Runs one command line and returns the exit status.
    /// Where start looks for netshield.toml without --config.
    public static var defaultConfigPath: String {
        NSHomeDirectory() + "/.config/netshield/netshield.toml"
    }

    public static func run(_ arguments: [String], stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void,
                           readFile: (String) throws -> Data = readConfigFile,
                           system: SystemControlling = UnsignedSystem()) -> Int32 {
        if arguments.isEmpty {
            stderr(usage)
            return ExitCode.usage
        }
        let command: Command
        do {
            command = try parse(arguments)
        } catch {
            stderr("netshield: \(error)")
            stderr("Run 'netshield help' for usage.")
            return ExitCode.usage
        }
        switch command {
        case .help:
            stdout(usage)
            return ExitCode.success
        case .validate(let path):
            switch loadConfig(path, readFile: readFile, stderr: stderr) {
            case .failure(let status): return status.code
            case .success(let loaded):
                stdout("\(path): valid (\(loaded.config.summary))")
                return ExitCode.success
            }
        case .daemon(let path):
            switch loadConfig(path, readFile: readFile, stderr: stderr) {
            case .failure(let status): return status.code
            case .success(let loaded):
                stdout("\(path): valid (\(loaded.config.summary))")
                stderr("netshield daemon: not implemented yet (needs the extension, phase 2)")
                return ExitCode.unavailable
            }
        case .start(let configPath):
            let path = configPath ?? defaultConfigPath
            switch loadConfig(path, readFile: readFile, stderr: stderr) {
            case .failure(let status): return status.code
            case .success(let loaded):
                stdout("\(path): valid (\(loaded.config.summary))")
                return system.start(configText: loaded.text, output: SystemOutput(stdout: stdout, stderr: stderr))
            }
        case .stop:
            return system.stop(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .status:
            return system.status(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .mode(let mode):
            return system.setMode(mode, output: SystemOutput(stdout: stdout, stderr: stderr))
        case .pending, .approve, .deny:
            stderr("netshield \(command.name): not implemented yet (needs the extension, phase 2)")
            return ExitCode.unavailable
        }
    }

    private struct Status: Error { let code: Int32 }

    /// The parsed file and the exact text it was parsed from, read once.
    private struct Loaded {
        let config: NetshieldConfig
        let text: String
    }

    /// Reads and parses a netshield.toml, reporting problems the way validate does.
    private static func loadConfig(_ path: String, readFile: (String) throws -> Data,
                                   stderr: (String) -> Void) -> Result<Loaded, Status> {
        let data: Data
        do {
            data = try readFile(path)
        } catch {
            stderr("\(path): cannot read the file: \(error.localizedDescription)")
            return .failure(Status(code: ExitCode.unreadable))
        }
        do {
            // NetshieldConfig refuses anything that is not UTF-8, so the text is always there.
            return .success(Loaded(config: try NetshieldConfig(data: data), text: String(decoding: data, as: UTF8.self)))
        } catch let error as ConfigError {
            stderr(error.line.map { "\(path):\($0): \(error.message)" } ?? "\(path): \(error.message)")
            return .failure(Status(code: ExitCode.invalidConfig))
        } catch {
            stderr("\(path): \(error)")
            return .failure(Status(code: ExitCode.invalidConfig))
        }
    }

    /// "30s", "10m", "1h": a positive whole number and one unit.
    public static func parseDuration(_ text: String) -> Int? {
        guard let unit = text.last, let factor = ["s": 1, "m": 60, "h": 3600][unit] else { return nil }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.count <= 6, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              digits.first != "0", let value = Int(digits) else { return nil }
        return value * factor
    }

    /// Reads at most one byte past the size limit, so a huge file is refused without loading it.
    public static func readConfigFile(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: NetshieldConfig.maximumBytes + 1) ?? Data()
    }

    private static func noArguments(_ command: String, _ rest: [String]) throws {
        guard rest.isEmpty else { throw UsageError("\(command) takes no arguments") }
    }

    /// --name value or --name=value, each at most once.
    private static func parseOptions(_ arguments: [String], allowed: Set<String>, command: String) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw UsageError("\(command): unexpected argument '\(printable(argument))'")
            }
            var name = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            guard allowed.contains(name) else { throw UsageError("\(command): unknown option --\(printable(name))") }
            let value: String
            if let inlineValue {
                value = inlineValue
            } else {
                guard index + 1 < arguments.count else { throw UsageError("\(command): --\(name) needs a value") }
                index += 1
                value = arguments[index]
            }
            guard options[name] == nil else { throw UsageError("\(command): --\(name) given twice") }
            guard !value.isEmpty else { throw UsageError("\(command): --\(name) needs a value") }
            options[name] = value
            index += 1
        }
        return options
    }

    private static func target(_ options: [String: String], command: String) throws -> (app: String, team: String?, host: String) {
        guard let app = options["app"] else { throw UsageError("\(command) needs --app") }
        guard validSigningID(app) else { throw UsageError("--app must be a signing identifier") }
        let team = options["team"]
        if let team, !validTeamID(team) { throw UsageError("--team must be a Team ID of 10 upper-case letters or digits") }
        guard let rawHost = options["host"] else { throw UsageError("\(command) needs --host") }
        guard let host = normalizeHost(rawHost) else {
            throw UsageError("--host must be one host name; wildcards and IP addresses are not accepted")
        }
        return (app, team, host)
    }

    private static func token(_ options: [String: String]) throws -> String? {
        guard let token = options["token"] else { return nil }
        guard token.utf8.count <= 128, token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw UsageError("--token must be the token from the event") }
        return token
    }

    /// Arguments echoed back in errors: printable ASCII only, cut at 64 characters.
    private static func printable(_ text: String) -> String {
        let kept = text.unicodeScalars.prefix(64).map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(kept) + (text.unicodeScalars.count > 64 ? "…" : "")
    }
}
