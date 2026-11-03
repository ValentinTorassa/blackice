import Foundation
import BlackiceCore

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
    case daemon
    case agent(AgentAction)

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
        case .agent: return "agent"
        }
    }
}

/// `blackice agent install` or `uninstall`: the daemon's LaunchAgent.
public enum AgentAction: String, Equatable, Sendable {
    case install, uninstall
}

public struct Approval: Equatable, Sendable {
    /// `--app/--team` (no team means Apple platform code), or `--cdhash` for ad hoc code.
    public let identity: AppIdentity
    public let host: String
    public let seconds: Int
    /// The event's one-time token; without it the command asks for Touch ID.
    public let token: String?

    public var request: AnswerRequest {
        AnswerRequest(kind: .approve, app: identity, host: host, seconds: seconds, token: token)
    }
}

public struct Denial: Equatable, Sendable {
    public let identity: AppIdentity
    public let host: String
    public let token: String?

    public var request: AnswerRequest {
        AnswerRequest(kind: .deny, app: identity, host: host, seconds: nil, token: token)
    }
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
    usage: blackice <command> [options]

    Commands:
      validate PATH                      Check a blackice.toml file
      start [--config PATH]              Activate the extension and start filtering with PATH
                                         (default ~/.config/blackice/blackice.toml)
      stop                               Stop filtering and deactivate the extension
      status                             Mode, rules, approvals and paused connections
      mode accept-all | ask | block-all  Change the mode
      pending                            Connections waiting for an answer, and the approvals
      approve (--app ID [--team TEAM] | --cdhash HEX) --host HOST [--for 1h] [--token TOKEN]
                                         Let one app reach one host until the approval expires
      deny (--app ID [--team TEAM] | --cdhash HEX) --host HOST [--token TOKEN]
                                         Drop the waiting connections and remove the approval
      daemon                             Run the hooks for paused connections (the LaunchAgent)
      agent install | uninstall          Load or remove the daemon's LaunchAgent for this user
      help                               Show this help

    validate works anywhere, and so does agent uninstall. agent install must run from
    inside Blackice.app. Every other command needs Blackice.app signed with the
    Developer ID; any other build says so and exits with status 69. start, stop and mode
    ask for Touch ID before changing filtering, and so do approve and deny without the
    event's --token. A token is good for one answer to its own event. agent install and
    uninstall do not ask for Touch ID.
    Without --team, --app names Apple platform code, which has no Team ID. --cdhash names
    ad hoc signed code by its CDHash (codesign -dvvv); a rebuild changes it.
    The daemon reads no file: it runs the hooks, with their timeout, of the configuration that
    start and mode saved, which it gets from the extension. Hooks get HOME, USER, LOGNAME, TMPDIR,
    PATH=\(HookRunner.defaultPath) and LANG=\(HookRunner.language), plus
    BLACKICE_EVENT_FILE and BLACKICE_EVENT_ID; a hook that needs more sets it in its run line.
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
            if rest.contains(where: { $0 == "--config" || $0.hasPrefix("--config=") }) {
                throw UsageError("daemon no longer takes --config: it runs the hooks of the configuration that " +
                                 "blackice start saved, which it gets from the network extension")
            }
            try noArguments(first, rest)
            return .daemon
        case "agent":
            guard rest.count == 1, let action = AgentAction(rawValue: rest[0]) else {
                throw UsageError("agent takes install or uninstall")
            }
            return .agent(action)
        case "approve":
            let options = try parseOptions(rest, allowed: ["app", "team", "cdhash", "host", "for", "token"], command: first)
            let target = try target(options, command: first)
            var seconds = defaultApprovalSeconds
            if let text = options["for"] {
                guard let parsed = parseDuration(text), parsed <= maximumApprovalSeconds else {
                    throw UsageError("--for takes a duration such as 30s, 10m or 1h, at most 24h")
                }
                seconds = parsed
            }
            return .approve(Approval(identity: target.identity, host: target.host, seconds: seconds,
                                     token: try token(options)))
        case "deny":
            let options = try parseOptions(rest, allowed: ["app", "team", "cdhash", "host", "token"], command: first)
            let target = try target(options, command: first)
            return .deny(Denial(identity: target.identity, host: target.host, token: try token(options)))
        default:
            throw UsageError("unknown command '\(printable(first))'")
        }
    }

    /// Runs one command line and returns the exit status.
    /// Where start looks for blackice.toml without --config.
    public static var defaultConfigPath: String {
        NSHomeDirectory() + "/.config/blackice/blackice.toml"
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
            stderr("blackice: \(error)")
            stderr("Run 'blackice help' for usage.")
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
        case .daemon:
            return system.runDaemon(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .agent(.install):
            return system.installAgent(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .agent(.uninstall):
            return system.uninstallAgent(output: SystemOutput(stdout: stdout, stderr: stderr))
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
        case .pending:
            return system.pending(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .approve(let approval):
            return system.answer(approval.request, output: SystemOutput(stdout: stdout, stderr: stderr))
        case .deny(let denial):
            return system.answer(denial.request, output: SystemOutput(stdout: stdout, stderr: stderr))
        }
    }

    private struct Status: Error { let code: Int32 }

    /// The parsed file and the exact text it was parsed from, read once.
    private struct Loaded {
        let config: BlackiceConfig
        let text: String
    }

    /// Reads and parses a blackice.toml, reporting problems the way validate does.
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
            // BlackiceConfig refuses anything that is not UTF-8, so the text is always there.
            return .success(Loaded(config: try BlackiceConfig(data: data), text: String(decoding: data, as: UTF8.self)))
        } catch let error as ConfigError {
            stderr(error.line.map { "\(path):\($0): \(error.message)" } ?? "\(path): \(error.message)")
            return .failure(Status(code: ExitCode.invalidConfig))
        } catch {
            stderr("\(path): \(error)")
            return .failure(Status(code: ExitCode.invalidConfig))
        }
    }

    /// What `blackice pending` prints. The fields came from the extension, already checked;
    /// none of them is a token.
    public static func pendingLines(_ reply: PendingReply) -> [String] {
        var lines: [String] = []
        if reply.events.isEmpty {
            lines.append("No connection is waiting.")
        } else {
            lines.append("Waiting:")
            for event in reply.events {
                let label = event.app.identity?.label ?? "unknown"
                // An event outlives its connections when they were dropped with hold_expired: it stays
                // open until its deadline, so an approval still covers the app's next try.
                let count = event.connections == 0 ? "no connection left (an approval covers the next try)"
                    : event.connections == 1 ? "1 connection" : "\(event.connections) connections"
                lines.append("  \(event.id)  \(label) -> \(event.host):\(event.port) (\(event.ip)), \(count), " +
                             "\(event.secondsLeft) s left")
                if let path = event.path { lines.append("      " + path) }
            }
        }
        if reply.approvals.isEmpty {
            lines.append("No approvals.")
        } else {
            lines.append("Approvals:")
            for approval in reply.approvals {
                lines.append("  \(approval.app.identity?.label ?? "unknown") -> \(approval.host), \(approval.secondsLeft) s left")
            }
        }
        return lines
    }

    /// The exit status for an answer: 0 when done, 77 when the token was refused, 64 for a
    /// request the extension found invalid, 69 when it could not answer.
    public static func answerStatus(_ reply: AnswerReply) -> Int32 {
        switch (reply.status, reply.reason) {
        case (.done, _): return ExitCode.success
        case (.refused, "invalid_request"): return ExitCode.usage
        case (.refused, "unavailable"): return ExitCode.unavailable
        case (.refused, _): return ExitCode.noPermission
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
        return try handle.read(upToCount: BlackiceConfig.maximumBytes + 1) ?? Data()
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

    /// `--app` with an optional `--team`, or `--cdhash` alone; and `--host`.
    private static func target(_ options: [String: String], command: String) throws -> (identity: AppIdentity, host: String) {
        let identity: AppIdentity
        if let cdhash = options["cdhash"] {
            guard options["app"] == nil, options["team"] == nil else {
                throw UsageError("\(command): --cdhash names ad hoc code; it cannot be combined with --app or --team")
            }
            guard let hash = normalizeCDHash(cdhash) else {
                throw UsageError("--cdhash must be 40 hex digits, the CDHash that codesign -dvvv prints")
            }
            identity = .cdhash(hash)
        } else {
            guard let app = options["app"] else { throw UsageError("\(command) needs --app or --cdhash") }
            guard validSigningID(app) else { throw UsageError("--app must be a signing identifier") }
            let team = options["team"]
            if let team, !validTeamID(team) { throw UsageError("--team must be a Team ID of 10 upper-case letters or digits") }
            identity = .signed(SigningIdentity(signingID: app, teamID: team))
        }
        guard let rawHost = options["host"] else { throw UsageError("\(command) needs --host") }
        guard let host = normalizeHost(rawHost) else {
            throw UsageError("--host must be one host name; wildcards and IP addresses are not accepted")
        }
        return (identity, host)
    }

    private static func token(_ options: [String: String]) throws -> String? {
        guard let token = options["token"] else { return nil }
        guard validEventToken(token) else { throw UsageError("--token must be the token from the event") }
        return token
    }

    /// Arguments echoed back in errors: printable ASCII only, cut at 64 characters.
    private static func printable(_ text: String) -> String {
        let kept = text.unicodeScalars.prefix(64).map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(kept) + (text.unicodeScalars.count > 64 ? "…" : "")
    }
}
