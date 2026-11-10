import Foundation
import BlackiceCore

/// Exit codes follow sysexits(3).
public enum ExitCode {
    public static let success: Int32 = 0
    public static let usage: Int32 = 64       // EX_USAGE
    public static let invalidConfig: Int32 = 65 // EX_DATAERR
    public static let unreadable: Int32 = 66  // EX_NOINPUT
    public static let unavailable: Int32 = 69 // EX_UNAVAILABLE: needs the signed app or the extension
    public static let cannotCreate: Int32 = 73 // EX_CANTCREAT: init found a file already there
    public static let software: Int32 = 70    // EX_SOFTWARE: a system request failed
    public static let tempFail: Int32 = 75    // EX_TEMPFAIL: the saved configuration changed meanwhile; retry
    public static let noPermission: Int32 = 77 // EX_NOPERM: Touch ID cancelled or failed
    public static let interrupted: Int32 = 130 // 128 + SIGINT, as shells report it: a setup stopped by Control-C
}

public enum Command: Equatable, Sendable {
    /// `blackice help`, or with a command's name its options.
    case help(String? = nil)
    case version
    case initConfig(path: String?)
    case start(configPath: String?)
    case stop, status, pending
    /// `blackice mode MODE`, and in ask mode `--agent NAME` for who answers.
    case mode(Mode, answerer: Answerer? = nil)
    case approve(Approval)
    case deny(Denial)
    /// `blackice deny --all`: forget every approval.
    case forgetApprovals
    case validate(path: String)
    case daemon
    case agent(AgentAction)
    /// `blackice agent connect NAME`: set an agent up to answer what waits in ask mode, with its
    /// default model or the one `--model` names.
    case connectAgent(name: String, configPath: String?, model: String? = nil)
    case menu(MenuRequest)
    /// `blackice report [--last 1h]`: the filter's flow log over the last `minutes`, summed up.
    case report(minutes: Int)

    public var name: String {
        switch self {
        case .help: return "help"
        case .version: return "version"
        case .initConfig: return "init"
        case .start: return "start"
        case .stop: return "stop"
        case .status: return "status"
        case .pending: return "pending"
        case .mode: return "mode"
        case .approve: return "approve"
        case .deny, .forgetApprovals: return "deny"
        case .validate: return "validate"
        case .daemon: return "daemon"
        case .agent, .connectAgent: return "agent"
        case .menu: return "menu"
        case .report: return "report"
        }
    }
}

/// `blackice menu` runs the menu bar app; `--login on|off` turns opening it at login on or off.
public enum MenuRequest: Equatable, Sendable {
    case run
    case login(Bool)
}

/// `blackice agent install` or `uninstall`: the daemon's LaunchAgent.
public enum AgentAction: String, Equatable, Sendable {
    case install, uninstall
}

public struct Approval: Equatable, Sendable {
    /// `--app/--team` (no team means Apple platform code), or `--cdhash` for ad hoc code.
    public let identity: AppIdentity
    /// One or more `--host`, in the order given, each once.
    public let hosts: [String]
    public let seconds: Int
    /// `--save`: after the approval, write a lasting `[[allow]]` rule for it in `configPath`, or
    /// in blackice.toml's usual place when nil.
    public let save: Bool
    public let configPath: String?
    /// `--script`: for an interpreter, the one script the approval covers; nil covers them all.
    public let script: String?

    public init(identity: AppIdentity, hosts: [String], seconds: Int, save: Bool = false, configPath: String? = nil,
                script: String? = nil) {
        self.identity = identity
        self.hosts = hosts
        self.seconds = seconds
        self.save = save
        self.configPath = configPath
        self.script = script
    }

    public init(identity: AppIdentity, host: String, seconds: Int) {
        self.init(identity: identity, hosts: [host], seconds: seconds)
    }

    /// A person's answer, one per host; the command asks for Touch ID once for all of them. Hooks
    /// answer on their stdout instead.
    public var requests: [AnswerRequest] {
        hosts.map { AnswerRequest(kind: .approve, app: identity, host: $0, seconds: seconds, token: nil, script: script) }
    }
}

public struct Denial: Equatable, Sendable {
    public let identity: AppIdentity
    public let host: String
    /// `--script`: for an interpreter, the one script the denial covers; nil covers them all.
    public let script: String?

    public init(identity: AppIdentity, host: String, script: String? = nil) {
        self.identity = identity
        self.host = host
        self.script = script
    }

    public var request: AnswerRequest {
        AnswerRequest(kind: .deny, app: identity, host: host, seconds: nil, token: nil, script: script)
    }
}

public struct UsageError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum CLI {
    public static let defaultApprovalSeconds = 3600
    public static let maximumApprovalSeconds = ApprovalTable.maximumSeconds
    /// `--host` options one `blackice approve` takes, so the Touch ID dialog can name them all.
    public static let maximumApprovalHosts = 16
    public static let defaultReportMinutes = 60
    /// A week: about as far back as unified logging keeps the filter's lines on a busy Mac.
    public static let maximumReportMinutes = 7 * 24 * 60

    public static let usage = """
    blackice: an app firewall for macOS

    Usage: blackice COMMAND [options]

      start                start filtering (Touch ID)
      status               what blackice is doing
      mode MODE            accept-all, ask or block-all (Touch ID)
      pending              what waits for an answer, and the approvals
      approve, deny        answer for one app and its hosts (Touch ID)
      report               what the filter dropped in the last hour
      agent connect NAME   let fx, claude-code, codex or opencode answer
      menu                 show blackice in the menu bar
      stop                 stop filtering and remove the extension (Touch ID)
      init, validate PATH, agent install|uninstall, version

    blackice help COMMAND shows a command's options.
    Docs: https://blackice-macos.vercel.app/docs
    """

    /// `blackice help COMMAND`: its usage line first, which errors repeat, then what it does.
    static let commandHelp: [String: [String]] = [
        "start": ["Usage: blackice start [--config PATH]", "",
                  "Starts filtering with ~/.config/blackice/blackice.toml, or PATH (Touch ID). With",
                  "no file there yet, it asks a few questions first. A mode or answerer switched",
                  "with blackice mode or the menu since the last start stays while the file is",
                  "unchanged."],
        "status": ["Usage: blackice status", "", "What blackice is doing: its mode, who answers and what waits."],
        "mode": ["Usage: blackice mode accept-all|ask|block-all [--agent NAME]", "",
                 "How blackice treats new connections (Touch ID):",
                 "  accept-all     every connection goes through and is logged",
                 "  ask            what no rule covers waits until you, or an agent, answers",
                 "  block-all      only what your rules allow goes through",
                 "  --agent NAME   who answers: fx, claude-code, codex, opencode or you"],
        "pending": ["Usage: blackice pending", "",
                    "The connections waiting for an answer, and the apps and hosts denied a moment",
                    "ago, whose connections are dropped without asking, each with the command that",
                    "approves it; then the approvals."],
        "approve": ["Usage: blackice approve --app ID [--team TEAM] --host HOST… [--for 1h]",
                    "                        [--script PATH | --save]", "",
                    "Lets one app reach one or more hosts for a while, and lets its waiting",
                    "connections through, with one Touch ID. blackice pending prints the command.",
                    "  --app ID       its signing identifier, with --team TEAM unless Apple signed it",
                    "  --cdhash HEX   in place of --app, for ad hoc signed code",
                    "  --host HOST    a host name, or an IP address for connections with no name;",
                    "                 repeat it for up to 16 hosts",
                    "  --for 1h       30s, 10m or 1h; at most 24h",
                    "  --script PATH  for an interpreter (python, node…), only this script: its",
                    "                 full path, or -m MODULE; without it, every script it runs",
                    "  --save         also add a lasting [[allow]] rule for it to blackice.toml",
                    "                 (or --config PATH); it counts from the next blackice start.",
                    "                 A rule for an interpreter (python, node…) never counts."],
        "deny": ["Usage: blackice deny --app ID [--team TEAM] --host HOST [--script PATH]",
                 "       blackice deny --all", "",
                 "Refuses one app one host, and drops its waiting connections (Touch ID).",
                 "--cdhash HEX in place of --app names ad hoc signed code; --script PATH, for",
                 "an interpreter, refuses only that script.",
                 "  --all   forgets every approval instead (Touch ID). What waits keeps waiting,",
                 "          remembered denials stay, and connections already let through go on."],
        "report": ["Usage: blackice report [--last 1h]", "",
                   "What the filter dropped, by reason and app, and in accept-all what ask mode",
                   "would have done. --last takes minutes or hours, such as 30m or 2h, at most 168h."],
        "agent": ["Usage: blackice agent connect NAME [--model NAME] [--config PATH]",
                  "       blackice agent install|uninstall", "",
                  "  connect NAME   sets fx, claude-code, codex or opencode up to answer what",
                  "                 waits in ask mode: its own home and sign-in, a test, its",
                  "                 rule and its hook",
                  "  --model NAME   the model it decides with; a small one by default, and",
                  "                 PROVIDER/MODEL for opencode, which otherwise asks for one",
                  "  install        runs the hooks for waiting connections, now and at each login",
                  "  uninstall      stops that"],
        "menu": ["Usage: blackice menu [--login on|off]", "",
                 "Shows blackice in the menu bar until you quit it. --login on also opens it at",
                 "each login; --login off stops that."],
        "init": ["Usage: blackice init [--config PATH]", "",
                 "Writes ~/.config/blackice/blackice.toml, or PATH, from a few questions."],
        "validate": ["Usage: blackice validate PATH", "", "Checks a blackice.toml without loading it."],
        "stop": ["Usage: blackice stop", "", "Stops filtering and removes the network extension (Touch ID)."],
        "version": ["Usage: blackice version"],
        "help": ["Usage: blackice help [COMMAND]"],
        "daemon": ["Usage: blackice daemon", "",
                   "Runs the hooks of the configuration blackice holds.", "launchd starts it: blackice agent install."],
    ]

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError("missing command") }
        let rest = Array(arguments.dropFirst())
        // `blackice COMMAND --help` is `blackice help COMMAND`.
        if commandHelp[first] != nil, first != "help", rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .help(first)
        }
        switch first {
        case "help", "-h", "--help":
            guard let topic = rest.first else { return .help() }
            guard rest.count == 1, commandHelp[topic] != nil else {
                throw UsageError("help: no command is called '\(printable(rest.joined(separator: " ")))'")
            }
            return .help(topic)
        case "version", "--version":
            try noArguments(first, rest)
            return .version
        case "init":
            let options = try parseOptions(rest, allowed: ["config"], command: first)
            if let path = options["config"], path.hasPrefix("-") { throw UsageError("init: --config needs a path") }
            return .initConfig(path: options["config"])
        case "start":
            let options = try parseOptions(rest, allowed: ["config"], command: first)
            if let path = options["config"], path.hasPrefix("-") { throw UsageError("start: --config needs a path") }
            return .start(configPath: options["config"])
        case "stop": try noArguments(first, rest); return .stop
        case "status": try noArguments(first, rest); return .status
        case "pending": try noArguments(first, rest); return .pending
        case "mode":
            guard let first = rest.first, let mode = Mode(rawValue: first) else {
                throw UsageError("mode takes accept-all, ask or block-all")
            }
            let options = try parseOptions(Array(rest.dropFirst()), allowed: ["agent"], command: "mode")
            guard let name = options["agent"] else { return .mode(mode) }
            guard mode == .ask else { throw UsageError("mode: --agent goes with ask") }
            guard let answerer = Answerer(name: name) else {
                throw UsageError("mode: --agent takes \(Answerer.all.map(\.name).joined(separator: ", ")), not '\(printable(name))'")
            }
            return .mode(mode, answerer: answerer)
        case "validate":
            guard rest.count == 1, !rest[0].isEmpty, !rest[0].hasPrefix("-") else {
                throw UsageError("validate takes one path")
            }
            return .validate(path: rest[0])
        case "daemon":
            if rest.contains(where: { $0 == "--config" || $0.hasPrefix("--config=") }) {
                throw UsageError("daemon takes no --config: it runs the hooks of what blackice start loaded")
            }
            try noArguments(first, rest)
            return .daemon
        case "agent":
            if rest.first == "connect" {
                let arguments = Array(rest.dropFirst())
                guard let name = arguments.first, !name.hasPrefix("-") else {
                    throw UsageError("agent connect takes fx, claude-code, codex or opencode")
                }
                let options = try parseOptions(Array(arguments.dropFirst()), allowed: ["config", "model"], command: "agent connect")
                if let path = options["config"], path.hasPrefix("-") { throw UsageError("agent connect: --config needs a path") }
                if let model = options["model"], !validModel(model) {
                    throw UsageError("agent connect: --model takes a model name, such as haiku or anthropic/claude-haiku-5.5")
                }
                return .connectAgent(name: name, configPath: options["config"], model: options["model"])
            }
            guard rest.count == 1, let action = AgentAction(rawValue: rest[0]) else {
                throw UsageError("agent takes install, uninstall or connect")
            }
            return .agent(action)
        case "menu":
            let options = try parseOptions(rest, allowed: ["login"], command: first)
            guard let value = options["login"] else { return .menu(.run) }
            guard let on = ["on": true, "off": false][value] else { throw UsageError("menu: --login takes on or off") }
            return .menu(.login(on))
        case "report":
            let options = try parseOptions(rest, allowed: ["last"], command: first)
            guard let text = options["last"] else { return .report(minutes: defaultReportMinutes) }
            guard let minutes = parseReportSpan(text) else {
                throw UsageError("report: --last takes minutes or hours, such as 30m or 2h, at most 168h")
            }
            return .report(minutes: minutes)
        case "approve":
            try noToken(rest, command: first)
            // --save is the one option with no value.
            let save = rest.contains("--save")
            let repeated = try parseOptions(rest.filter { $0 != "--save" },
                                            allowed: ["app", "team", "cdhash", "host", "for", "config", "script"], repeatable: ["host"],
                                            command: first)
            let options = repeated.compactMapValues(\.first)
            let app = try identity(options, command: first)
            let raws = repeated["host"] ?? []
            guard !raws.isEmpty else { throw UsageError("\(first) needs --host") }
            guard raws.count <= maximumApprovalHosts else {
                throw UsageError("\(first): at most \(maximumApprovalHosts) --host at once")
            }
            var hosts: [String] = []
            for raw in raws {
                let normalized = try host(raw, command: first)
                guard !hosts.contains(normalized) else { throw UsageError("\(first): --host \(normalized) given twice") }
                hosts.append(normalized)
            }
            var seconds = defaultApprovalSeconds
            if let text = options["for"] {
                guard let parsed = parseDuration(text) else {
                    throw UsageError("\(first): --for takes 30s, 10m or 1h, at most 24h")
                }
                seconds = parsed
            }
            if let path = options["config"] {
                guard save else { throw UsageError("\(first): --config goes with --save") }
                guard !path.hasPrefix("-") else { throw UsageError("\(first): --config needs a path") }
            }
            let script = try options["script"].map { try self.script($0, command: first) }
            // A rule covers every script of an interpreter, and never counts for one: there is no
            // rule for one script to save.
            if script != nil, save { throw UsageError("\(first): --script and --save do not go together") }
            return .approve(Approval(identity: app, hosts: hosts, seconds: seconds, save: save, configPath: options["config"],
                                     script: script))
        case "deny":
            try noToken(rest, command: first)
            if rest.contains("--all") {
                guard rest == ["--all"] else { throw UsageError("\(first): --all takes nothing else; it forgets every approval") }
                return .forgetApprovals
            }
            let options = try parseOptions(rest, allowed: ["app", "team", "cdhash", "host", "script"], command: first)
            let target = try target(options, command: first)
            let script = try options["script"].map { try self.script($0, command: first) }
            return .deny(Denial(identity: target.identity, host: target.host, script: script))
        default:
            throw UsageError("unknown command '\(printable(first))'")
        }
    }

    /// `approve --save`: adds a rule for the approved app and the hosts no rule covers yet to the
    /// end of blackice.toml, through the same compare-and-replace `agent connect` uses. The running
    /// filter keeps its configuration, so the rule counts from the next `blackice start`; the
    /// approval covers the hosts until then.
    static func saveRule(_ approval: Approval, readFile: (String) throws -> Data,
                         stdout: (String) -> Void, stderr: (String) -> Void) -> Int32 {
        let path = approval.configPath ?? defaultConfigPath
        let shown = Describe.terminalSafe(Describe.path(path, home: NSHomeDirectory()))
        let text: String
        let config: BlackiceConfig
        do {
            text = String(decoding: try readFile(path), as: UTF8.self)
            config = try BlackiceConfig(text: text)
        } catch {
            stderr("blackice approve: approved, but not saved: cannot read \(shown) (\(error))")
            return ExitCode.unreadable
        }
        let missing = approval.hosts.filter { config.allowRule(for: approval.identity, host: $0) == nil }
        guard !missing.isEmpty else {
            stdout(Style.done("\(shown) already has a rule for \(approval.identity.name) to these hosts"))
            return ExitCode.success
        }
        let reference = AppReference(approval.identity)
        var lines = ["", "# Added by blackice approve --save for \(approval.identity.name)."
                         + (reference.cdhash == nil ? "" : " That build only: an upgrade changes its cdhash."),
                     "[[allow]]"]
        if let cdhash = reference.cdhash { lines.append("cdhash = \"\(cdhash)\"") }
        if let signingID = reference.signingID { lines.append("app = \"\(signingID)\"") }
        if let teamID = reference.teamID { lines.append("team = \"\(teamID)\"") }
        lines.append("hosts = [" + missing.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        let updated = text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n"
        do {
            _ = try BlackiceConfig(text: updated)
            var info = stat()
            let mode = stat(path, &info) == 0 ? info.st_mode & 0o777 : 0o600
            try writeAtomically(Data(updated.utf8), to: path, mode: mode, replacing: Data(text.utf8))
        } catch is ChangedMeanwhile {
            stderr("blackice approve: approved, but not saved: \(shown) changed meanwhile; run it again")
            return ExitCode.tempFail
        } catch {
            stderr("blackice approve: approved, but not saved in \(shown): \(error)")
            return ExitCode.cannotCreate
        }
        stdout(Style.done("Saved a rule for \(approval.identity.name) → \(missing.joined(separator: ", ")) in \(shown);"
                          + " it counts from the next blackice start"))
        if case .cdhash = approval.identity {
            stdout("  If that cdhash is an interpreter (python, node, a shell…), the rule never counts: blackice decides")
            stdout("  an interpreter's connections one by one. Name the tool in the agent's notes instead.")
        }
        return ExitCode.success
    }

    /// Where start looks for blackice.toml without --config.
    public static var defaultConfigPath: String {
        NSHomeDirectory() + "/.config/blackice/blackice.toml"
    }

    /// Runs one command line and returns the exit status.
    public static func run(_ arguments: [String], stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void,
                           readFile: (String) throws -> Data = readConfigFile,
                           system: SystemControlling = UnsignedSystem(),
                           interaction: Interaction = .none, agents: AgentMachine = .none,
                           menuBar: MenuBarControlling = NoMenuBar()) -> Int32 {
        if arguments.isEmpty {
            stderr(usage)
            return ExitCode.usage
        }
        let command: Command
        do {
            command = try parse(arguments)
        } catch {
            stderr("blackice: \(error)")
            stderr(commandHelp[arguments[0]]?.first ?? "Run: blackice help")
            return ExitCode.usage
        }
        switch command {
        case .help(nil):
            stdout(usage)
            return ExitCode.success
        case .help(let topic?):
            (commandHelp[topic] ?? []).forEach(stdout)
            return ExitCode.success
        case .version:
            stdout(interaction.version.map { "blackice \($0)" } ?? "blackice (a build outside Blackice.app)")
            return ExitCode.success
        case .initConfig(let configPath):
            let path = configPath ?? defaultConfigPath
            let shown = Describe.path(path, home: interaction.home)
            if interaction.fileExists(path) {
                stderr("\(shown) is already there. Check it with: blackice validate \(shown)")
                return ExitCode.cannotCreate
            }
            guard interaction.ask != nil else {
                stderr("blackice init asks a few questions, so it needs a terminal.")
                return ExitCode.usage
            }
            let (status, agent) = writeConfig(at: path, heading: nil, interaction: interaction,
                                              stdout: stdout, stderr: stderr)
            if status == ExitCode.success {
                let option = configPath == nil ? "" : " --config \(shown)"
                stdout("Next: " + Style.command("blackice start" + option) +
                       (agent.map { ", then " + Style.command("blackice agent connect \($0)" + option) } ?? ""))
            }
            return status
        case .validate(let path):
            switch loadConfig(path, readFile: readFile, stderr: stderr) {
            case .failure(let status): return status.code
            case .success(let loaded):
                stdout("✓ \(path) is valid: \(loaded.config.overview)")
                return ExitCode.success
            }
        case .daemon:
            return system.runDaemon(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .agent(.install):
            return system.installAgent(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .agent(.uninstall):
            return system.uninstallAgent(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .connectAgent(let name, let configPath, let model):
            return connectAgent(name, configPath: configPath, model: model, readFile: readFile, system: system, interaction: interaction,
                                machine: agents, stdout: stdout, stderr: stderr)
        case .menu(.run):
            return menuBar.run(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .menu(.login(let on)):
            return menuBar.setOpenAtLogin(on, output: SystemOutput(stdout: stdout, stderr: stderr))
        case .start(let configPath):
            let path = configPath ?? defaultConfigPath
            let shown = Describe.path(path, home: interaction.home)
            var justWritten = false
            var agent: String?
            if isMissing(path, readFile: readFile) {
                guard interaction.ask != nil else {
                    stderr("There is no configuration at \(shown) yet. Write one with: blackice init" +
                           (configPath == nil ? "" : " --config \(shown)"))
                    return ExitCode.unreadable
                }
                let written = writeConfig(at: path, heading: "1 · Pick a mode", interaction: interaction,
                                          stdout: stdout, stderr: stderr)
                guard written.status == ExitCode.success else { return written.status }
                justWritten = true
                agent = written.agent
            }
            switch loadConfig(path, readFile: readFile, stderr: stderr, shown: shown, hint: true) {
            case .failure(let status): return status.code
            case .success(let loaded):
                guard let agent, loaded.config.mode != .acceptAll else {
                    // A file just written by the questions is loaded as written; otherwise a switch
                    // made with blackice mode or the menu stays while the file leaves it as it was.
                    let started = system.start(configText: loaded.text,
                                               output: SystemOutput(stdout: stdout, stderr: stderr, setup: justWritten,
                                                                    asWritten: justWritten))
                    if started == ExitCode.success { menuBar.openAfterStart(output: SystemOutput(stdout: stdout, stderr: stderr)) }
                    if justWritten, started == ExitCode.success {
                        offerMenuBar(menuBar, interaction: interaction, stdout: stdout, stderr: stderr)
                    }
                    return started
                }
                // The agent's installer, sign-in and test need the network: start in accept-all, set
                // the agent up, and let its last step load the file in the mode picked. Nothing was
                // filtered before, so a setup that does not get there stays in accept-all and says so.
                let started = system.start(configText: settingRootKey(loaded.text, "mode", to: "\"accept-all\""),
                                           output: SystemOutput(stdout: stdout, stderr: stderr, setup: true, next: false,
                                                                asWritten: true))
                guard started == ExitCode.success else { return started }
                menuBar.openAfterStart(output: SystemOutput(stdout: stdout, stderr: stderr))
                stdout("  " + Style.done("blackice is on in accept-all mode until \(agent) is set up"))
                let connected = connectAgent(agent, configPath: configPath, readFile: readFile, system: system,
                                             interaction: interaction, machine: agents, stdout: stdout, stderr: stderr,
                                             heading: "4 · Connect \(agent)", fromFirstStart: true)
                if connected == ExitCode.success {
                    offerMenuBar(menuBar, interaction: interaction, stdout: stdout, stderr: stderr)
                }
                return connected
            }
        case .stop:
            return system.stop(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .status:
            return system.status(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .mode(let mode, let answerer):
            return system.setMode(mode, answerer: answerer, output: SystemOutput(stdout: stdout, stderr: stderr))
        case .pending:
            return system.pending(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .approve(let approval):
            let status = system.answer(all: approval.requests, output: SystemOutput(stdout: stdout, stderr: stderr))
            guard approval.save, status == ExitCode.success else { return status }
            return saveRule(approval, readFile: readFile, stdout: stdout, stderr: stderr)
        case .deny(let denial):
            return system.answer(denial.request, output: SystemOutput(stdout: stdout, stderr: stderr))
        case .forgetApprovals:
            return system.forgetApprovals(output: SystemOutput(stdout: stdout, stderr: stderr))
        case .report(let minutes):
            // Taken before `log show` runs, so every event counted has its ask line in what it reads.
            let now = Date()
            let result = system.flowLog(minutes: minutes)
            guard result.status == 0 else {
                let last = result.output.split(separator: "\n").last.map { String($0.prefix(200)) } ?? "no output"
                stderr("blackice report: \(FlowLog.program) show exited with status \(result.status): " +
                       Describe.terminalSafe(last))
                return result.status == 127 ? ExitCode.unavailable : ExitCode.software
            }
            let received = system.receivedEvents(in: ReceivedEvents.window(minutes: minutes, before: now))
            FlowReport(logText: result.output).summary(last: reportSpan(minutes), received: received).forEach(stdout)
            return ExitCode.success
        }
    }

    struct Status: Error { let code: Int32 }

    /// The parsed file and the exact text it was parsed from, read once.
    struct Loaded {
        let config: BlackiceConfig
        let text: String
    }

    /// Reads and parses a blackice.toml, reporting problems the way validate does. With `hint`, a
    /// problem also says how to go on, as start does.
    static func loadConfig(_ path: String, readFile: (String) throws -> Data, stderr: (String) -> Void,
                                   shown: String? = nil, hint: Bool = false) -> Result<Loaded, Status> {
        let name = shown ?? path
        let data: Data
        do {
            data = try readFile(path)
        } catch {
            if isMissingFile(error) {
                stderr(hint ? "There is no configuration at \(name). Write one with: blackice init" : "\(name): there is no such file")
            } else {
                stderr("\(name): cannot read the file: \(error.localizedDescription)")
            }
            return .failure(Status(code: ExitCode.unreadable))
        }
        do {
            // BlackiceConfig refuses anything that is not UTF-8, so the text is always there.
            return .success(Loaded(config: try BlackiceConfig(data: data), text: String(decoding: data, as: UTF8.self)))
        } catch let error as ConfigError {
            stderr(error.line.map { "\(name):\($0): \(error.message)" } ?? "\(name): \(error.message)")
        } catch {
            stderr("\(name): \(error)")
        }
        if hint { stderr("Fix the file, then check it with: blackice validate \(name)") }
        return .failure(Status(code: ExitCode.invalidConfig))
    }

    static func isMissing(_ path: String, readFile: (String) throws -> Data) -> Bool {
        do {
            _ = try readFile(path)
            return false
        } catch {
            return isMissingFile(error)
        }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isMissingFile(underlying) }
        return false
    }

    /// Asks the wizard's questions under a step title and creates the file. The text is parsed
    /// before it is written, so the file always loads.
    private static func writeConfig(at path: String, heading: String?, interaction: Interaction,
                                    stdout: @escaping (String) -> Void, stderr: (String) -> Void) -> (status: Int32, agent: String?) {
        guard let ask = interaction.ask else { return (ExitCode.usage, nil) }
        let wizard = ConfigWizard(ask: ask, say: stdout, identify: interaction.identify,
                                  fileExists: interaction.fileExists, home: interaction.home,
                                  choose: interaction.choose, runningApps: interaction.runningApps,
                                  networkExtensions: interaction.networkExtensions, helpers: interaction.helpers,
                                  isTunnel: interaction.isTunnel)
        let shown = Describe.path(path, home: interaction.home)
        if let heading { stdout(Style.heading(heading)) }
        guard let answers = wizard.run() else {
            stderr("Nothing was written.")
            return (ExitCode.unreadable, nil)
        }
        let text = ConfigWizard.render(answers)
        let parsed: BlackiceConfig
        do {
            parsed = try BlackiceConfig(data: Data(text.utf8))
        } catch {
            stderr("blackice init: the file it would write does not parse (\(error)); nothing was written")
            return (ExitCode.software, nil)
        }
        do {
            try interaction.createFile(path, Data(text.utf8))
        } catch {
            stderr("Cannot write \(shown): \(error.localizedDescription)")
            return (ExitCode.cannotCreate, nil)
        }
        // What the questions decided; hooks come later, from agent connect.
        stdout("  " + Style.done("Saved \(shown): \(parsed.mode.rawValue) mode, \(Describe.count(parsed.allow.count, "rule"))"))
        return (ExitCode.success, answers.agent)
    }

    /// Creates `path` with mode 0644, and its folder with 0700 if it is missing. Fails if the file
    /// is already there.
    public static func createFile(_ path: String, _ data: Data) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// What `blackice pending` prints. The fields came from the extension, already checked;
    /// none of them is a token. The path is wherever the app runs from, so it is escaped.
    public static func pendingLines(_ reply: PendingReply) -> [String] {
        if reply.events.isEmpty, reply.approvals.isEmpty, reply.denials.isEmpty { return ["Nothing waiting, and no approvals."] }
        var lines: [String] = []
        if !reply.events.isEmpty {
            lines.append(Style.heading("Waiting"))
            for event in reply.events {
                let identity = event.app.identity
                // An event outlives its connections when they were dropped with hold_expired: it stays
                // open until its deadline, so an approval still covers the app's next try.
                let held = event.connections == 0 ? "none held" : Describe.count(event.connections, "connection")
                lines.append("  \(identity?.name ?? "unknown app") → \(event.hostAndPort)  \(held), \(Describe.left(event.secondsLeft)) left")
                // A signing identifier says which app it is; ad hoc code is known by where it runs.
                if case .signed? = identity {} else if let path = event.path { lines.append("    " + Describe.terminalSafe(path)) }
                // An interpreter's script, which its command line names: it tells tools apart, and proves nothing.
                if let script = event.script { lines.append("    running " + Describe.terminalSafe(script)) }
                // With no script to read, the title the process gave itself: `npm run build`.
                if let title = event.title { lines.append("    calls itself " + Describe.terminalSafe(title)) }
                if let identity {
                    lines.append("    " + Style.command(approveCommand(identity, hosts: [event.host], script: event.script)))
                }
            }
        } else if reply.denials.isEmpty {
            lines.append("Nothing waiting.")
        }
        // An app's connections to a host denied a moment ago are dropped with no event, so nothing
        // shows as waiting while it fails. They come next, each app's hosts together and then the
        // command that approves them all.
        if !reply.denials.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(Style.heading("Denied, dropped without asking"))
            let format = columns(reply.denials)
            for group in byApp(reply.denials) {
                lines += group.map(format)
                guard let identity = group[0].app.identity else { continue }
                for start in stride(from: 0, to: group.count, by: maximumApprovalHosts) {
                    let hosts = group[start..<min(start + maximumApprovalHosts, group.count)].map(\.host)
                    lines.append("    " + Style.command(approveCommand(identity, hosts: hosts, script: group[0].script)))
                }
            }
        }
        if !reply.approvals.isEmpty {
            lines += ["", Style.heading("Approvals")]
            lines += reply.approvals.map(columns(reply.approvals))
        }
        return lines
    }

    /// Rows of app → host and the time left, in columns as wide as the longest app and host; an
    /// interpreter's entry for one script says so after the time.
    private static func columns(_ entries: [ApprovalSummary]) -> (ApprovalSummary) -> String {
        let nameWidth = min(entries.map { name($0).count }.max() ?? 0, 40)
        let hostWidth = min(entries.map(\.host.count).max() ?? 0, 40)
        return { entry in
            let label = name(entry)
            let scope: String
            switch entry.scope {
            case .any: scope = ""
            case .script(let script?): scope = "  running " + Describe.script(script)
            case .script(nil): scope = "  with no script"
            }
            return "  " + label.padding(toLength: max(label.count, nameWidth), withPad: " ", startingAt: 0) + " → " +
                entry.host.padding(toLength: max(entry.host.count, hostWidth), withPad: " ", startingAt: 0) +
                "  " + Describe.left(entry.secondsLeft) + scope
        }
    }

    private static func name(_ entry: ApprovalSummary) -> String { entry.app.identity?.name ?? "unknown app" }

    /// The entries of each app and script together, in the order they first appear.
    private static func byApp(_ entries: [ApprovalSummary]) -> [[ApprovalSummary]] {
        var groups: [[ApprovalSummary]] = []
        var index: [String: Int] = [:]
        for entry in entries {
            let key = (entry.app.identity?.label ?? "") + "\u{0}" + (entry.script ?? "") + (entry.noScript == true ? "\u{0}" : "")
            if let at = index[key] { groups[at].append(entry) } else { index[key] = groups.count; groups.append([entry]) }
        }
        return groups
    }

    /// The `blackice approve` line for an app and host, as `pending` shows it.
    static func approveCommand(_ identity: AppIdentity, host: String) -> String {
        approveCommand(identity, hosts: [host])
    }

    /// The `blackice approve` line for an app and its hosts, one `--host` each. For an
    /// interpreter's script that an answer can name and the terminal shows as it is, `--script`
    /// too, quoted for the shell; otherwise the line approves every script, which only a person
    /// with Touch ID can.
    static func approveCommand(_ identity: AppIdentity, hosts: [String], script: String? = nil) -> String {
        let hostOptions = hosts.map { " --host \($0)" }.joined()
        let scriptOption = script.flatMap { ScriptScope.canName($0) && Describe.terminalSafe($0) == $0 ? $0 : nil }
            .map { " --script " + shellQuoted($0) } ?? ""
        switch identity {
        case .signed(let signed):
            return "blackice approve --app \(signed.signingID)" + (signed.teamID.map { " --team \($0)" } ?? "") + hostOptions
                + scriptOption
        case .cdhash(let hash):
            return "blackice approve --cdhash \(hash)" + hostOptions + scriptOption
        }
    }

    /// One shell word: as it is when it has only characters no shell treats specially, otherwise
    /// in single quotes, with each single quote closed, escaped and opened again.
    static func shellQuoted(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "/._-+,:@%=".unicodeScalars.contains($0)
        }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The exit status for an answer: 0 when done, 77 when the extension refused it, 64 for a
    /// request the extension found invalid, 69 when it could not answer.
    public static func answerStatus(_ reply: AnswerReply) -> Int32 {
        switch (reply.status, reply.reason) {
        case (.done, _): return ExitCode.success
        case (.refused, "invalid_request"): return ExitCode.usage
        case (.refused, "unavailable"): return ExitCode.unavailable
        case (.refused, _): return ExitCode.noPermission
        }
    }

    /// "30s", "10m", "1h": a positive whole number and one unit, at most 24 h. A hook's answer
    /// takes the same durations, in minutes and hours (`ApprovalDuration`).
    public static func parseDuration(_ text: String) -> Int? {
        ApprovalDuration.seconds(text)
    }

    /// `report --last`: "30m" or "2h", a positive whole number with no leading zero and one unit,
    /// at most a week. Returns minutes.
    public static func parseReportSpan(_ text: String) -> Int? {
        guard let unit = text.last, let factor = ["m": 1, "h": 60][unit] else { return nil }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.count <= 6, digits.utf8.allSatisfy({ (48...57).contains($0) }), digits.first != "0",
              let value = Int(digits), value * factor <= maximumReportMinutes else { return nil }
        return value * factor
    }

    /// Minutes as `report` says them back: "2h", or "90m" when they are not whole hours.
    static func reportSpan(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
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
        try parseOptions(arguments, allowed: allowed, repeatable: [], command: command).compactMapValues(\.first)
    }

    /// --name value or --name=value, each at most once unless `repeatable` names it; the values of
    /// each in the order given.
    private static func parseOptions(_ arguments: [String], allowed: Set<String>, repeatable: Set<String>,
                                     command: String) throws -> [String: [String]] {
        var options: [String: [String]] = [:]
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
            guard options[name] == nil || repeatable.contains(name) else { throw UsageError("\(command): --\(name) given twice") }
            guard !value.isEmpty else { throw UsageError("\(command): --\(name) needs a value") }
            options[name, default: []].append(value)
            index += 1
        }
        return options
    }

    /// `--script`: an interpreter's script as `pending` shows it.
    private static func script(_ text: String, command: String) throws -> String {
        guard ScriptScope.canName(text) else {
            throw UsageError("\(command): --script takes the script's full path, or -m MODULE, as blackice pending shows it")
        }
        return text
    }

    /// `--app` with an optional `--team`, or `--cdhash` alone; and `--host`.
    private static func target(_ options: [String: String], command: String) throws -> (identity: AppIdentity, host: String) {
        (try identity(options, command: command), try host(options["host"], command: command))
    }

    /// `--app` with an optional `--team`, or `--cdhash` alone.
    private static func identity(_ options: [String: String], command: String) throws -> AppIdentity {
        let identity: AppIdentity
        if let cdhash = options["cdhash"] {
            guard options["app"] == nil, options["team"] == nil else {
                throw UsageError("\(command): --cdhash names ad hoc code; it cannot be combined with --app or --team")
            }
            guard let hash = normalizeCDHash(cdhash) else {
                throw UsageError("\(command): --cdhash takes 40 hex digits, the CDHash that codesign -dvvv prints")
            }
            identity = .cdhash(hash)
        } else {
            guard let app = options["app"] else { throw UsageError("\(command) needs --app or --cdhash") }
            guard validSigningID(app) else { throw UsageError("\(command): --app takes a signing identifier, such as com.apple.curl") }
            let team = options["team"]
            if let team, !validTeamID(team) { throw UsageError("\(command): --team takes a Team ID, 10 capital letters or digits") }
            identity = .signed(SigningIdentity(signingID: app, teamID: team))
        }
        return identity
    }

    /// One `--host`: a host name or an IP address, normalized.
    private static func host(_ rawHost: String?, command: String) throws -> String {
        guard let rawHost else { throw UsageError("\(command) needs --host") }
        // An address covers connections to it that have no name, as `pending` shows them.
        if let address = IPAddress.strict(rawHost), !address.isCheckable {
            throw UsageError("\(command): --host needs a link-local address's interface, such as fe80::1%en0")
        }
        guard let host = normalizeDestination(rawHost) else {
            throw UsageError("\(command): --host takes one host name or IP address, with no wildcards, ranges or leading zeros")
        }
        return host
    }

    /// `--token` went in 0.4.0: hooks answer on their stdout, and the daemon answers for them.
    private static func noToken(_ arguments: [String], command: String) throws {
        if arguments.contains(where: { $0 == "--token" || $0.hasPrefix("--token=") }) {
            throw UsageError("\(command) takes no --token: a hook answers with its last line of output, and by hand \(command) asks for Touch ID")
        }
    }

    /// Arguments echoed back in errors: printable ASCII only, cut at 64 characters.
    private static func printable(_ text: String) -> String {
        let kept = text.unicodeScalars.prefix(64).map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(kept) + (text.unicodeScalars.count > 64 ? "…" : "")
    }
}
