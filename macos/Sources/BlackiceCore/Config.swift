import Foundation

// blackice.toml: a strict reader for the small subset of TOML the file uses.
//
// Accepted: comments, bare keys, "basic" and 'literal' strings on one line, decimal
// integers, true/false, arrays of those (they may span lines), the [[allow]] and [[hook]]
// tables, and one [agent] table (`answers` and `notes`; `notes` alone may be a multi-line string, """…""" or
// '''…'''). Everything else in TOML is refused with a line number instead of being guessed
// at: dotted or quoted keys, other [tables], inline tables, multi-line strings elsewhere,
// a backslash at the end of a line, floats, dates, other number forms, unknown keys and
// duplicate keys.

public enum Mode: String, CaseIterable, Sendable {
    case acceptAll = "accept-all"
    case ask
    case blockAll = "block-all"
}

/// A permanent rule: this code may reach these hosts, in every mode.
public struct AllowRule: Equatable, Sendable {
    /// The code the rule names: a signing identifier and Team ID (`app` and `team`), checked
    /// against the running code, or the cdhash of one ad hoc build (`cdhash`). A cdhash rule never
    /// counts for an interpreter (see `Interpreters`).
    public let code: AppIdentity
    /// The host name entries. Empty when `anyHost` is set.
    public let hosts: [DomainPattern]
    /// The address and CIDR entries. A flow whose remote address is in one is allowed by that
    /// address, with or without a host name, and no host, address or server name check applies.
    public let addresses: [AddressRange]
    /// `hosts = ["*"]`: the app may reach any destination, including flows with only an address
    /// and no host name. No host or address check applies.
    public let anyHost: Bool
    /// Line of the rule's [[allow]] header.
    public let line: Int

    /// The signing identifier; nil for a cdhash rule.
    public var app: String? {
        if case .signed(let identity) = code { return identity.signingID }
        return nil
    }

    /// The Team ID; nil for Apple platform code, which is signed without one, and for a cdhash rule.
    public var team: String? {
        if case .signed(let identity) = code { return identity.teamID }
        return nil
    }

    /// The cdhash, 40 lower-case hex digits; nil for a rule with `app`.
    public var cdhash: String? {
        if case .cdhash(let hash) = code { return hash }
        return nil
    }

    public func names(_ code: AppIdentity) -> Bool { self.code == code }

    public func names(_ identity: SigningIdentity) -> Bool { names(.signed(identity)) }

    /// Whether the rule names this host. Always false for a `*` rule, which names no host:
    /// see `BlackiceConfig.anyHostRule(for:)`. `host` must already be normalized.
    public func matches(_ code: AppIdentity, host: String) -> Bool {
        names(code) && hosts.contains { $0.matches(host) }
    }

    /// Whether the rule names this code and an address entry holds this address.
    public func matches(_ code: AppIdentity, address: IPAddress) -> Bool {
        names(code) && addresses.contains { $0.contains(address) }
    }
}

/// What a [[hook]] runs for each event: a shell command line (`run`), or an executable (`program`)
/// that the daemon starts directly and checks against its code signature first. Either way it
/// answers on its stdout (see `HookAnswer`).
public struct Hook: Equatable, Sendable {
    /// The only event so far is "connection".
    public let on: String
    /// The command line to run with `/bin/sh -c`. Nothing checks what the shell then runs, so a
    /// program of the user that replaces it (fx in ~/.local/bin, say) answers in its place.
    public let run: String?
    /// The executable to run, checked against its signature before each run.
    public let program: HookProgram?
    /// Line of the hook's [[hook]] header.
    public let line: Int

    public init(on: String = "connection", run: String, line: Int) {
        self.on = on
        self.run = run
        program = nil
        self.line = line
    }

    public init(on: String = "connection", program: HookProgram, line: Int) {
        self.on = on
        run = nil
        self.program = program
        self.line = line
    }

    /// The command as one string, for finding a hook by what it runs: `run`, or the program and
    /// its arguments separated by spaces.
    public var commandText: String {
        run ?? program.map { ([$0.path] + $0.arguments).joined(separator: " ") } ?? ""
    }
}

/// `program`, `args`, `env`, `app`, `team`, `stdin` and `instructions` in a [[hook]].
public struct HookProgram: Equatable, Sendable {
    /// Absolute. Started directly, with no shell and no PATH lookup.
    public let path: String
    /// argv[1...]; argv[0] is `path`.
    public let arguments: [String]
    /// Set on top of the environment the daemon builds; `env = ["NAME=value", ...]` in the file.
    public let environment: [String: String]
    /// The signing identifier and Team ID the program must have: the kernel starts it only with
    /// them (HookRunner.launchRequirement), and the daemon checks the running code again as
    /// [[allow]] rules check apps. No Team ID means Apple platform code.
    public let identity: SigningIdentity
    /// Whether the event comes on stdin too (`stdin = "event"`, the default); with `"none"` it is
    /// only in its file. Since 1.0.3 a hook that names its `instructions` has no event file and
    /// always gets the event on stdin, whatever this says.
    public let eventOnStdin: Bool
    /// The agent whose instructions the daemon passes the program, with the owner's notes, in the
    /// agent's own flags or environment (`instructions = "claude-code"`; AgentInstructions.launch),
    /// from blackice itself rather than a file any program of the user could change. nil passes none.
    public let instructions: AgentInstructions?

    public init(path: String, arguments: [String] = [], environment: [String: String] = [:], identity: SigningIdentity,
                eventOnStdin: Bool = true, instructions: AgentInstructions? = nil) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
        self.identity = identity
        self.eventOnStdin = eventOnStdin
        self.instructions = instructions
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    /// 1-based line, or nil for a problem with the whole file.
    public let line: Int?
    public let message: String

    public init(line: Int?, _ message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

public struct BlackiceConfig: Equatable, Sendable {
    public static let maximumBytes = 65_536
    public static let defaultTimeoutSeconds = 10
    /// Provisional. The upper bound comes down once the paused flow lifetime is measured.
    public static let timeoutRange = 1...120
    public static let maximumAllowRules = 256
    public static let maximumHostsPerRule = 256
    public static let maximumHooks = 8
    public static let maximumRunBytes = 4096
    /// For `program`, each of `args` and each `env` entry.
    public static let maximumHookStringBytes = 4096
    public static let maximumHookArguments = 64
    public static let maximumHookEnvironment = 64
    /// `notes` in [agent], in UTF-8.
    public static let maximumNotesBytes = 4096

    public let mode: Mode
    public let timeoutSeconds: Int
    /// Whether the built-in allowance for macOS's own services applies (see `AppleServices`).
    /// `apple_services = false` turns it off; it is on by default.
    public let appleServices: Bool
    /// Whether connections to 127.0.0.0/8 and ::1 pass in every mode, before any rule.
    /// `loopback = false` filters them like any other; it is on by default.
    public let loopback: Bool
    public let allow: [AllowRule]
    public let hooks: [Hook]
    /// The owner's own guidance for the deciding agent (`notes` in [agent]): plain text, which the
    /// daemon passes an agent's program hook after its instructions, and writes as notes.md into
    /// the directory of a hook that names no instructions. It is part of the configuration, so it is loaded with Touch ID like
    /// the hooks. nil when unset or blank.
    public let agentNotes: String?
    /// Who answers in ask mode (`answers` in [agent]). nil when unset: every hook runs.
    public let answers: Answerer?

    public init(data: Data) throws {
        guard !data.isEmpty else { throw ConfigError(line: nil, "the file is empty") }
        guard data.count <= Self.maximumBytes else {
            throw ConfigError(line: nil, "the file is larger than \(Self.maximumBytes / 1024) KiB")
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw ConfigError(line: 1, "byte order marks are not supported") }
        guard String(data: data, encoding: .utf8) != nil else { throw ConfigError(line: nil, "the file is not valid UTF-8") }
        var parser = Parser(bytes: Array(data))
        let document = try parser.parse()
        self = try Self.build(document)
    }

    public init(text: String) throws { try self.init(data: Data(text.utf8)) }

    private init(mode: Mode, timeoutSeconds: Int, appleServices: Bool, loopback: Bool, allow: [AllowRule], hooks: [Hook],
                 agentNotes: String?, answers: Answerer?) {
        self.mode = mode
        self.timeoutSeconds = timeoutSeconds
        self.appleServices = appleServices
        self.loopback = loopback
        self.allow = allow
        self.hooks = hooks
        self.agentNotes = agentNotes
        self.answers = answers
    }

    /// The hooks the daemon runs: every one with no `answers`; otherwise each hook that is no
    /// agent's (it names no `instructions`) and the hook of the agent `answers` names. With
    /// `answers = "you"`, no agent's hook runs, and people answer.
    public var activeHooks: [Hook] {
        guard let answers else { return hooks }
        return hooks.filter { hook in
            guard let instructions = hook.program?.instructions else { return true }
            return answers == .agent(instructions)
        }
    }

    /// The agents with hooks, and which of them answers.
    public var answering: Answering {
        var agents: [AgentInstructions] = []
        for case let instructions? in hooks.map({ $0.program?.instructions }) where !agents.contains(instructions) {
            agents.append(instructions)
        }
        let answerer = answers ?? (agents.isEmpty ? .you : agents.count == 1 ? .agent(agents[0]) : nil)
        return Answering(agents: agents, answerer: answerer)
    }

    /// The first rule that names this code and this host, if any. Rules say nothing about ports.
    /// A `*` rule names no host; see `anyHostRule(for:)`.
    public func allowRule(for code: AppIdentity, host: String) -> AllowRule? {
        guard let host = normalizeHost(host) else { return nil }
        return allow.first { $0.matches(code, host: host) }
    }

    public func allowRule(for identity: SigningIdentity, host: String) -> AllowRule? {
        allowRule(for: .signed(identity), host: host)
    }

    /// The first `hosts = ["*"]` rule for this code, if any.
    public func anyHostRule(for code: AppIdentity) -> AllowRule? {
        allow.first { $0.anyHost && $0.names(code) }
    }

    public func anyHostRule(for identity: SigningIdentity) -> AllowRule? { anyHostRule(for: .signed(identity)) }

    /// The first rule that names this code and has an address entry that holds this address.
    public func addressRule(for code: AppIdentity, address: IPAddress) -> AllowRule? {
        allow.first { $0.matches(code, address: address) }
    }

    public func addressRule(for identity: SigningIdentity, address: IPAddress) -> AllowRule? {
        addressRule(for: .signed(identity), address: address)
    }

    /// Whether any rule names this code, for any host.
    public func hasRule(for code: AppIdentity) -> Bool {
        allow.contains { $0.names(code) }
    }

    public var summary: String {
        let rules = allow.count == 1 ? "1 allow rule" : "\(allow.count) allow rules"
        let hookCount = hooks.count == 1 ? "1 hook" : "\(hooks.count) hooks"
        return "mode \(mode.rawValue), timeout \(timeoutSeconds) s, \(rules), \(hookCount)"
            + (appleServices ? "" : ", apple_services off") + (loopback ? "" : ", loopback off")
            + (agentNotes == nil ? "" : ", notes for the agent") + (answers.map { ", \($0.title) answers" } ?? "")
    }
}

// MARK: - Building the configuration from the parsed tables

extension BlackiceConfig {
    private static func build(_ document: Document) throws -> BlackiceConfig {
        let root = document.root
        guard let modeEntry = root.entries["mode"] else { throw ConfigError(line: nil, "missing required key 'mode'") }
        let modeText = try modeEntry.string("mode")
        guard let mode = Mode(rawValue: modeText) else {
            throw ConfigError(line: modeEntry.line, "mode must be \"accept-all\", \"ask\" or \"block-all\", not \(quoted(modeText))")
        }
        var timeout = defaultTimeoutSeconds
        if let entry = root.entries["timeout_seconds"] {
            timeout = try entry.integer("timeout_seconds")
            guard timeoutRange.contains(timeout) else {
                throw ConfigError(line: entry.line, "timeout_seconds must be between \(timeoutRange.lowerBound) and \(timeoutRange.upperBound)")
            }
        }
        var appleServices = true
        if let entry = root.entries["apple_services"] {
            appleServices = try entry.bool("apple_services")
        }
        var loopback = true
        if let entry = root.entries["loopback"] {
            loopback = try entry.bool("loopback")
        }
        let allowTables = document.tables.filter { $0.kind == .allow }
        let hookTables = document.tables.filter { $0.kind == .hook }
        if allowTables.count > maximumAllowRules {
            throw ConfigError(line: allowTables[maximumAllowRules].line, "more than \(maximumAllowRules) [[allow]] rules")
        }
        if hookTables.count > maximumHooks {
            throw ConfigError(line: hookTables[maximumHooks].line, "more than \(maximumHooks) [[hook]] tables")
        }
        let agentTables = document.tables.filter { $0.kind == .agent }
        if agentTables.count > 1 {
            throw ConfigError(line: agentTables[1].line, "[agent] appears twice (first on line \(agentTables[0].line))")
        }
        let hooks = try hookTables.map(hook)
        var answers: Answerer?
        if let entry = agentTables.first?.entries["answers"] {
            let name = try entry.string("answers")
            guard let answerer = Answerer(name: name) else {
                throw ConfigError(line: entry.line, "answers must be \(Answerer.names), not \(quoted(name))")
            }
            // Naming an agent with no hook would leave nobody answering, unseen.
            if case .agent(let instructions) = answerer, !hooks.contains(where: { $0.program?.instructions == instructions }) {
                throw ConfigError(line: entry.line, "answers names \(quoted(name)), but no [[hook]] has instructions = " +
                                  "\(quoted(name)): blackice agent connect \(name)")
            }
            answers = answerer
        }
        return BlackiceConfig(mode: mode, timeoutSeconds: timeout, appleServices: appleServices, loopback: loopback,
                               allow: try allowTables.map(allowRule), hooks: hooks,
                               agentNotes: try agentTables.first?.entries["notes"].flatMap(notes), answers: answers)
    }

    /// `text` with `answers = "NAME"` in its [agent] table: the line replaced when it is there,
    /// added under `[agent]` when it is not, and the table added at the end when there is none.
    /// The rest of the text stays as it is. Throws when `text`, or the result, does not parse.
    public static func settingAnswers(_ answerer: Answerer, in text: String) throws -> String {
        try replacingAnswers(answerer, in: text, comment: "")
    }

    /// What `switchingAnswers` ends the `answers` line with, before what the file itself has.
    static let switchComment = "  # set by blackice mode; blackice.toml has "

    /// What the file had for `answers` before `blackice mode --agent` or the menu switched it in
    /// the text blackice holds. `fileHas` is nil when the file named no one.
    public struct SwitchedAnswers: Equatable, Sendable {
        public let fileHas: Answerer?
        public init(fileHas: Answerer?) { self.fileHas = fileHas }
    }

    /// `text` with `answers = "NAME"` as a switch sets it in the text blackice holds, never in the
    /// file: as `settingAnswers` does, with a comment at the end of that line that keeps what the
    /// file itself has, such as `answers = "codex"  # set by blackice mode; blackice.toml has "fx"`
    /// (or `has none`). `blackice start` reads the comment to tell a switch from a change in the
    /// file. A text switched before keeps the value its comment names, not the earlier switch.
    public static func switchingAnswers(_ answerer: Answerer, in text: String) throws -> String {
        // A record of `has none` is a record too: `?.fileHas ?? ...` read it as no record, so a
        // second switch wrote the first switch's answerer as the file's.
        let fileHas: Answerer?
        if let switched = try switchedAnswers(in: text) {
            fileHas = switched.fileHas
        } else {
            fileHas = try BlackiceConfig(text: text).answers
        }
        let named = fileHas.map { "\"\($0.name)\"" } ?? "none"
        return try replacingAnswers(answerer, in: text, comment: switchComment + named)
    }

    /// The comment `switchingAnswers` left on the `answers` line of `text`, read strictly: the
    /// whole line is `answers = "NAME"` followed by that comment, and it names a valid value. nil
    /// when there is none, so the text holds the file's own `answers`.
    public static func switchedAnswers(in text: String) throws -> SwitchedAnswers? {
        var parser = Parser(bytes: Array(text.utf8))
        let document = try parser.parse()
        guard let agent = document.tables.first(where: { $0.kind == .agent }),
              let entry = agent.entries["answers"],
              let answers = try BlackiceConfig(text: text).answers else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard entry.line - 1 < lines.count else { return nil }
        var line = lines[entry.line - 1]
        if line.hasSuffix("\r") { line.removeLast() }
        let prefix = "answers = \"\(answers.name)\"" + switchComment
        guard line.hasPrefix(prefix) else { return nil }
        let named = String(line.dropFirst(prefix.count))
        if named == "none" { return SwitchedAnswers(fileHas: nil) }
        guard named.count > 2, named.hasPrefix("\""), named.hasSuffix("\""),
              let fileHas = Answerer(name: String(named.dropFirst().dropLast())) else { return nil }
        return SwitchedAnswers(fileHas: fileHas)
    }

    private static func replacingAnswers(_ answerer: Answerer, in text: String, comment: String) throws -> String {
        var parser = Parser(bytes: Array(text.utf8))
        let document = try parser.parse()
        // A file with CRLF line ends keeps them.
        let end = text.contains("\r\n") ? "\r" : ""
        let line = "answers = \"\(answerer.name)\"" + comment + end
        var result: String
        if let agent = document.tables.first(where: { $0.kind == .agent }) {
            var lines = text.components(separatedBy: "\n")
            if let entry = agent.entries["answers"] {
                lines[entry.line - 1] = line
            } else {
                lines.insert(line, at: agent.line)
            }
            result = lines.joined(separator: "\n")
        } else {
            result = text
            // By byte: "\r\n" is one Character, so hasSuffix("\n") is false after it.
            if let last = result.utf8.last, last != UInt8(ascii: "\n") { result += end + "\n" }
            result += end + "\n[agent]" + end + "\n" + line + "\n"
        }
        guard try BlackiceConfig(text: result).answers == answerer else {
            throw ConfigError(line: nil, "answers could not be set")
        }
        return result
    }

    /// `notes` in [agent]: plain text of at most `maximumNotesBytes`, lines and tabs but no other
    /// control characters, and none of the Unicode controls that reorder or hide text, so what the
    /// agent reads is what the owner sees in the file. nil when blank.
    private static func notes(_ entry: Entry) throws -> String? {
        let text = try entry.string("notes")
        guard text.utf8.count <= maximumNotesBytes else {
            throw ConfigError(line: entry.line, "notes is longer than \(maximumNotesBytes / 1024) KiB")
        }
        if let bad = text.unicodeScalars.first(where: { ($0 != "\n" && isControl($0)) || isBidiControl($0) }) {
            throw ConfigError(line: entry.line, "notes must be plain text, without the control character U+" +
                              String(format: "%04X", bad.value))
        }
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }

    /// `app` and `team`, the same in [[allow]] and in a [[hook]] with `program`.
    private static func signingIdentity(_ table: Table, missing: String) throws -> SigningIdentity {
        guard let appEntry = table.entries["app"] else { throw ConfigError(line: table.line, missing) }
        let app = try appEntry.string("app")
        guard validSigningID(app) else {
            throw ConfigError(line: appEntry.line, "app must be a signing identifier (letters, digits, '-', '.', '_'), not \(quoted(app))")
        }
        var team: String?
        if let entry = table.entries["team"] {
            let text = try entry.string("team")
            guard validTeamID(text) else {
                throw ConfigError(line: entry.line, "team must be a Team ID of 10 upper-case letters or digits, not \(quoted(text))")
            }
            team = text
        }
        return SigningIdentity(signingID: app, teamID: team)
    }

    /// `app` and `team`, or `cdhash` alone, in [[allow]].
    private static func ruleCode(_ table: Table) throws -> AppIdentity {
        guard let entry = table.entries["cdhash"] else {
            return .signed(try signingIdentity(table, missing: "[[allow]] needs an 'app' or a 'cdhash' key"))
        }
        if let appEntry = table.entries["app"] {
            throw ConfigError(line: max(entry.line, appEntry.line), "[[allow]] takes 'app' or 'cdhash', not both")
        }
        // A cdhash names one build, and ad hoc code has no Team ID to check.
        if let teamEntry = table.entries["team"] { throw ConfigError(line: teamEntry.line, "team goes with app, not cdhash") }
        let text = try entry.string("cdhash")
        // One spelling, the one codesign -dvvv and `blackice approve` lines print, as addresses have one.
        if let lower = normalizeCDHash(text), lower != text {
            throw ConfigError(line: entry.line, "cdhash must be lower case; write \(quoted(lower))")
        }
        guard validCDHash(text) else {
            throw ConfigError(line: entry.line, "cdhash must be 40 hex digits, the CDHash that codesign -dvvv prints, " +
                              "not \(quoted(text))")
        }
        return .cdhash(text)
    }

    private static func allowRule(_ table: Table) throws -> AllowRule {
        let code = try ruleCode(table)
        guard let hostsEntry = table.entries["hosts"] else { throw ConfigError(line: table.line, "[[allow]] needs a 'hosts' key") }
        guard case .array(let items) = hostsEntry.value else {
            throw ConfigError(line: hostsEntry.line, "hosts must be an array of strings, not \(hostsEntry.value.typeName)")
        }
        guard !items.isEmpty else { throw ConfigError(line: hostsEntry.line, "hosts must not be empty") }
        guard items.count <= maximumHostsPerRule else {
            throw ConfigError(line: hostsEntry.line, "hosts has more than \(maximumHostsPerRule) entries")
        }
        if items.contains(.string("*")) {
            // Any destination. On its own only, so a typo next to a real host cannot widen a rule
            // by accident, and a reader sees at once what the rule allows.
            guard items.count == 1 else {
                throw ConfigError(line: hostsEntry.line, "\"*\" must be the only entry in hosts")
            }
            return AllowRule(code: code, hosts: [], addresses: [], anyHost: true, line: table.line)
        }
        var patterns: [DomainPattern] = []
        var addresses: [AddressRange] = []
        var seen = Set<String>()
        for item in items {
            guard case .string(let text) = item else {
                throw ConfigError(line: hostsEntry.line, "hosts must be an array of strings, but it holds \(item.typeName)")
            }
            let key: String
            if AddressRange.looksLikeAddress(text) {
                let range = try addressRange(text, line: hostsEntry.line)
                key = range.canonical
                addresses.append(range)
            } else {
                guard let pattern = DomainPattern(text) else {
                    throw ConfigError(line: hostsEntry.line, "\(quoted(text)) is not a host name, a *.domain pattern, " +
                                      "an IP address or a CIDR range")
                }
                key = (pattern.wildcard ? "*" : "") + pattern.suffix
                patterns.append(pattern)
            }
            guard seen.insert(key).inserted else {
                throw ConfigError(line: hostsEntry.line, "\(quoted(text)) appears twice in hosts")
            }
        }
        return AllowRule(code: code, hosts: patterns, addresses: addresses, anyHost: false, line: table.line)
    }

    /// An address or CIDR entry in hosts, or an error that says how to write it.
    private static func addressRange(_ text: String, line: Int) throws -> AddressRange {
        switch AddressRange.parse(text) {
        case .success(let range):
            return range
        case .failure(.notAnAddress):
            throw ConfigError(line: line, "\(quoted(text)) is not an IP address or a CIDR range; IPv4 is four numbers " +
                              "from 0 to 255 with no leading zeros, such as \"10.0.0.5\" or \"100.64.0.0/10\"")
        case .failure(.zone):
            throw ConfigError(line: line, "\(quoted(text)) names an interface; write the address without %")
        case .failure(.mapped):
            throw ConfigError(line: line, "\(quoted(text)) is an IPv4-mapped IPv6 address; write the IPv4 address")
        case .failure(.prefix(let maximum)):
            throw ConfigError(line: line, "the prefix of \(quoted(text)) must be a number from 1 to \(maximum)")
        case .failure(.hostBits(let network)):
            throw ConfigError(line: line, "\(quoted(text)) has bits set after its prefix; write \(quoted(network))")
        case .failure(.everything):
            throw ConfigError(line: line, "\(quoted(text)) covers every address; write hosts = [\"*\"] for any destination")
        }
    }

    private static func hook(_ table: Table) throws -> Hook {
        guard let onEntry = table.entries["on"] else { throw ConfigError(line: table.line, "[[hook]] needs an 'on' key") }
        let on = try onEntry.string("on")
        guard on == "connection" else {
            throw ConfigError(line: onEntry.line, "on must be \"connection\", not \(quoted(on))")
        }
        if let runEntry = table.entries["run"], let programEntry = table.entries["program"] {
            throw ConfigError(line: max(runEntry.line, programEntry.line), "[[hook]] takes 'program' or 'run', not both")
        }
        if let programEntry = table.entries["program"] {
            return Hook(on: on, program: try program(programEntry, in: table), line: table.line)
        }
        guard let runEntry = table.entries["run"] else {
            throw ConfigError(line: table.line, "[[hook]] needs a 'program' or a 'run' key")
        }
        for key in ["args", "env", "app", "team", "stdin", "instructions"] {
            if let entry = table.entries[key] { throw ConfigError(line: entry.line, "\(key) goes with program, not run") }
        }
        let run = try runEntry.string("run")
        guard !run.allSatisfy({ $0 == " " || $0 == "\t" }) else { throw ConfigError(line: runEntry.line, "run must not be empty") }
        guard run.utf8.count <= maximumRunBytes else {
            throw ConfigError(line: runEntry.line, "run is longer than \(maximumRunBytes) bytes")
        }
        guard !run.unicodeScalars.contains(where: isControl) else {
            throw ConfigError(line: runEntry.line, "run must be one line with no control characters")
        }
        return Hook(on: on, run: run, line: table.line)
    }

    private static func program(_ entry: Entry, in table: Table) throws -> HookProgram {
        let path = try entry.string("program")
        guard path.hasPrefix("/"), path.utf8.count <= HookEvent.maximumPathBytes, !path.unicodeScalars.contains(where: isControl) else {
            throw ConfigError(line: entry.line, "program must be an absolute path, not \(quoted(path))")
        }
        let identity = try signingIdentity(
            table, missing: "[[hook]] with program needs an 'app' key: the signing identifier the program must have")
        var arguments: [String] = []
        if let argsEntry = table.entries["args"] {
            arguments = try strings(argsEntry, "args", at: maximumHookArguments)
        }
        var environment: [String: String] = [:]
        if let envEntry = table.entries["env"] {
            for item in try strings(envEntry, "env", at: maximumHookEnvironment) {
                guard let equals = item.firstIndex(of: "=") else {
                    throw ConfigError(line: envEntry.line, "env entries are NAME=value, not \(quoted(item))")
                }
                let name = String(item[..<equals])
                guard validEnvironmentName(name), !name.hasPrefix("BLACKICE_") else {
                    throw ConfigError(line: envEntry.line, "\(quoted(name)) is not a variable name a hook may set " +
                                      "(letters, digits and '_'; BLACKICE_ is the daemon's)")
                }
                guard environment[name] == nil else { throw ConfigError(line: envEntry.line, "\(name) is set twice in env") }
                environment[name] = String(item[item.index(after: equals)...])
            }
        }
        var eventOnStdin = true
        if let stdinEntry = table.entries["stdin"] {
            let stdin = try stdinEntry.string("stdin")
            guard ["event", "none"].contains(stdin) else {
                throw ConfigError(line: stdinEntry.line, "stdin must be \"event\" or \"none\", not \(quoted(stdin))")
            }
            eventOnStdin = stdin == "event"
        }
        var instructions: AgentInstructions?
        if let entry = table.entries["instructions"] {
            let name = try entry.string("instructions")
            guard let set = AgentInstructions(rawValue: name) else {
                throw ConfigError(line: entry.line, "instructions must be \(AgentInstructions.names), not \(quoted(name))")
            }
            instructions = set
        }
        return HookProgram(path: path, arguments: arguments, environment: environment, identity: identity,
                           eventOnStdin: eventOnStdin, instructions: instructions)
    }

    /// An array of at most `limit` strings, each at most `maximumHookStringBytes` with no control
    /// characters other than tab.
    private static func strings(_ entry: Entry, _ key: String, at limit: Int) throws -> [String] {
        guard case .array(let items) = entry.value else {
            throw ConfigError(line: entry.line, "\(key) must be an array of strings, not \(entry.value.typeName)")
        }
        guard items.count <= limit else { throw ConfigError(line: entry.line, "\(key) has more than \(limit) entries") }
        return try items.map { item in
            guard case .string(let text) = item else {
                throw ConfigError(line: entry.line, "\(key) must be an array of strings, but it holds \(item.typeName)")
            }
            guard text.utf8.count <= maximumHookStringBytes, !text.unicodeScalars.contains(where: isControl) else {
                throw ConfigError(line: entry.line, "\(key) entries must be at most \(maximumHookStringBytes) bytes " +
                                  "with no control characters")
            }
            return text
        }
    }
}

/// C0 controls other than tab, DEL and C1 controls.
private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value < 0x20 && scalar.value != 0x09) || (0x7F...0x9F).contains(scalar.value)
}

/// The bidirectional embeddings, overrides and isolates, which make text read in another order
/// than it is stored.
private func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
    (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
}

/// An ASCII letter or '_', then letters, digits and '_'.
func validEnvironmentName(_ name: String) -> Bool {
    guard let first = name.utf8.first, !(48...57).contains(first) else { return false }
    return name.utf8.count <= 255 && name.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
    }
}

/// A value from the file, safe to print: printable ASCII is kept, the rest is escaped, and long values are cut.
func quoted(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars.prefix(64) {
        if (0x20...0x7E).contains(scalar.value), scalar != "\"", scalar != "\\" {
            out.unicodeScalars.append(scalar)
        } else {
            out += "\\u{" + String(scalar.value, radix: 16) + "}"
        }
    }
    return "\"" + out + (text.unicodeScalars.count > 64 ? "…" : "") + "\""
}

// MARK: - Parsed document

private enum Value: Equatable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([Value])

    var typeName: String {
        switch self {
        case .string: return "a string"
        case .integer: return "an integer"
        case .bool: return "a boolean"
        case .array: return "an array"
        }
    }
}

private struct Entry {
    let value: Value
    let line: Int

    func string(_ key: String) throws -> String {
        guard case .string(let text) = value else { throw ConfigError(line: line, "\(key) must be a string, not \(value.typeName)") }
        return text
    }

    func integer(_ key: String) throws -> Int {
        guard case .integer(let number) = value else { throw ConfigError(line: line, "\(key) must be an integer, not \(value.typeName)") }
        return number
    }

    func bool(_ key: String) throws -> Bool {
        guard case .bool(let flag) = value else { throw ConfigError(line: line, "\(key) must be true or false, not \(value.typeName)") }
        return flag
    }
}

private enum TableKind: String {
    case root, allow, hook, agent

    var keys: Set<String> {
        switch self {
        case .root: return ["mode", "timeout_seconds", "apple_services", "loopback"]
        case .allow: return ["app", "team", "cdhash", "hosts"]
        case .hook: return ["on", "run", "program", "args", "env", "app", "team", "stdin", "instructions"]
        case .agent: return ["notes", "answers"]
        }
    }

    var label: String {
        switch self {
        case .root: return "at the top level"
        case .agent: return "in [agent]"
        case .allow, .hook: return "in [[\(rawValue)]]"
        }
    }
}

private struct Table {
    let kind: TableKind
    let line: Int
    var entries: [String: Entry] = [:]
}

private struct Document {
    var root = Table(kind: .root, line: 1)
    var tables: [Table] = []
}

// MARK: - Parser

private struct Parser {
    static let maximumArrayItems = 1024

    let bytes: [UInt8]
    var index = 0
    var line = 1

    init(bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index >= bytes.count }
    var current: UInt8? { atEnd ? nil : bytes[index] }

    func peek(_ offset: Int) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    func fail(_ message: String) -> ConfigError { ConfigError(line: line, message) }

    mutating func parse() throws -> Document {
        var document = Document()
        while !atEnd {
            skipSpaces()
            guard let byte = current else { break }
            if try consumeNewline() { continue }
            if byte == UInt8(ascii: "#") { try skipComment(); continue }
            if byte == UInt8(ascii: "[") {
                document.tables.append(try parseHeader())
                continue
            }
            let keyLine = line
            let key = try parseKey()
            skipSpaces()
            guard current == UInt8(ascii: "=") else {
                if current == UInt8(ascii: ".") { throw fail("dotted keys are not supported") }
                throw fail("expected '=' after the key '\(key)'")
            }
            index += 1
            skipSpaces()
            // Only the agent's notes may span lines.
            let value = try parseValue(inArray: false, multiline: key == "notes")
            try expectEndOfLine()
            if document.tables.isEmpty {
                try add(key, value, line: keyLine, to: &document.root)
            } else {
                try add(key, value, line: keyLine, to: &document.tables[document.tables.count - 1])
            }
        }
        return document
    }

    func add(_ key: String, _ value: Value, line keyLine: Int, to table: inout Table) throws {
        guard table.kind.keys.contains(key) else {
            var message = "unknown key '\(key)' \(table.kind.label)"
            if table.kind != .root, TableKind.root.keys.contains(key) {
                message += "; top-level keys go before the first table"
            }
            throw ConfigError(line: keyLine, message)
        }
        if let first = table.entries[key] {
            throw ConfigError(line: keyLine, "duplicate key '\(key)' \(table.kind.label) (first set on line \(first.line))")
        }
        table.entries[key] = Entry(value: value, line: keyLine)
    }

    mutating func parseHeader() throws -> Table {
        let headerLine = line
        guard peek(1) == UInt8(ascii: "[") else {
            // [agent], the one table that is not an array of tables.
            index += 1
            skipSpaces()
            guard let first = current, isBareKeyByte(first) else { throw fail("expected [agent], [[allow]] or [[hook]]") }
            let name = try parseKey()
            skipSpaces()
            if current == UInt8(ascii: ".") { throw fail("dotted table names are not supported") }
            guard current == UInt8(ascii: "]") else { throw fail("expected ']' after the table name") }
            index += 1
            try expectEndOfLine()
            switch name {
            case "agent": return Table(kind: .agent, line: headerLine)
            case "allow", "hook": throw ConfigError(line: headerLine, "[\(name)] needs double brackets: [[\(name)]]")
            default: throw ConfigError(line: headerLine, "unknown table [\(name)]; only [agent], [[allow]] and [[hook]] are supported")
            }
        }
        index += 2
        skipSpaces()
        let name = try parseKey()
        skipSpaces()
        if current == UInt8(ascii: ".") { throw fail("dotted table names are not supported") }
        guard current == UInt8(ascii: "]"), peek(1) == UInt8(ascii: "]") else { throw fail("expected ']]' after the table name") }
        index += 2
        try expectEndOfLine()
        switch name {
        case "allow": return Table(kind: .allow, line: headerLine)
        case "hook": return Table(kind: .hook, line: headerLine)
        case "agent": throw ConfigError(line: headerLine, "[agent] is a single table: write [agent], not [[agent]]")
        default: throw ConfigError(line: headerLine, "unknown table [[\(name)]]; only [agent], [[allow]] and [[hook]] are supported")
        }
    }

    mutating func parseKey() throws -> String {
        if current == UInt8(ascii: "\"") || current == UInt8(ascii: "'") { throw fail("quoted keys are not supported") }
        let start = index
        while let byte = current, isBareKeyByte(byte) { index += 1 }
        guard index > start else {
            if let byte = current, isControlByte(byte) { throw fail("control character outside a string") }
            throw fail("expected a key")
        }
        guard index - start <= 64 else { throw fail("key longer than 64 characters") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func parseValue(inArray: Bool, multiline: Bool = false) throws -> Value {
        guard let byte = current else { throw fail("expected a value") }
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            if peek(1) == byte, peek(2) == byte {
                guard multiline else { throw fail("multi-line strings are not supported here; only notes in [agent] takes one") }
                return .string(try parseMultilineString())
            }
            return .string(try byte == UInt8(ascii: "\"") ? parseBasicString() : parseLiteralString())
        case UInt8(ascii: "["):
            if inArray { throw fail("nested arrays are not supported") }
            return .array(try parseArray())
        case UInt8(ascii: "{"):
            throw fail("inline tables are not supported")
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"):
            return .integer(try parseInteger())
        default:
            let start = index
            while let next = current, isBareKeyByte(next) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            if word.isEmpty { throw fail("expected a value") }
            throw fail("unsupported value '\(word.prefix(32))'; strings need quotes")
        }
    }

    mutating func parseInteger() throws -> Int {
        let start = index
        while let byte = current, isBareKeyByte(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") {
            index += 1
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        let digitsOnly = !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) }
        guard digitsOnly, token == "0" || !token.hasPrefix("0"), token.count <= 9, let value = Int(token) else {
            throw fail("unsupported number '\(token.prefix(32))'; write a plain decimal integer such as 10")
        }
        return value
    }

    mutating func parseBasicString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard let byte = current, byte != 0x0A, byte != 0x0D else { throw fail("unterminated string") }
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard current != nil else { throw fail("unterminated string") }
                out += try parseEscape()
            default:
                if isControlByte(byte) && byte != 0x09 { throw fail("control character in string") }
                out.append(byte)
            }
        }
    }

    /// What follows a backslash in a basic string.
    mutating func parseEscape() throws -> [UInt8] {
        guard let escape = current else { throw fail("invalid escape in string") }
        index += 1
        switch escape {
        case UInt8(ascii: "\""): return [0x22]
        case UInt8(ascii: "\\"): return [0x5C]
        case UInt8(ascii: "b"): return [0x08]
        case UInt8(ascii: "t"): return [0x09]
        case UInt8(ascii: "n"): return [0x0A]
        case UInt8(ascii: "f"): return [0x0C]
        case UInt8(ascii: "r"): return [0x0D]
        case UInt8(ascii: "u"): return try parseUnicodeEscape(digits: 4)
        case UInt8(ascii: "U"): return try parseUnicodeEscape(digits: 8)
        default: throw fail("invalid escape in string")
        }
    }

    /// A """basic""" or '''literal''' string over several lines, as TOML reads them: a line break
    /// right after the opening quotes is dropped, CRLF reads as LF, one or two quotes just before
    /// the closing three belong to the string, and a basic one takes the escapes of a one-line
    /// string. A backslash at the end of a line, which TOML uses to join lines, is refused.
    mutating func parseMultilineString() throws -> String {
        let quote = bytes[index]
        let basic = quote == UInt8(ascii: "\"")
        let startLine = line
        index += 3
        if current == 0x0A {
            index += 1; line += 1
        } else if current == 0x0D, peek(1) == 0x0A {
            index += 2; line += 1
        }
        var out: [UInt8] = []
        while true {
            guard let byte = current else { throw ConfigError(line: startLine, "unterminated multi-line string") }
            if byte == quote, peek(1) == quote, peek(2) == quote {
                var run = 3
                while peek(run) == quote { run += 1 }
                guard run <= 5 else { throw fail("more than five quotes end a multi-line string") }
                out += Array(repeating: quote, count: run - 3)
                index += run
                return String(decoding: out, as: UTF8.self)
            }
            if try consumeNewline() {
                out.append(0x0A)
                continue
            }
            index += 1
            if basic, byte == UInt8(ascii: "\\") {
                guard let next = current else { throw ConfigError(line: startLine, "unterminated multi-line string") }
                if next == 0x0A || next == 0x0D {
                    throw fail("a backslash at the end of a line is not supported; write the text as it should read")
                }
                out += try parseEscape()
                continue
            }
            if isControlByte(byte) && byte != 0x09 { throw fail("control character in string") }
            out.append(byte)
        }
    }

    mutating func parseUnicodeEscape(digits: Int) throws -> [UInt8] {
        guard index + digits <= bytes.count else { throw fail("invalid escape in string") }
        let hex = String(decoding: bytes[index..<(index + digits)], as: UTF8.self)
        guard hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw fail("invalid escape in string")
        }
        index += digits
        return Array(String(Character(scalar)).utf8)
    }

    mutating func parseLiteralString() throws -> String {
        index += 1
        let start = index
        while true {
            guard let byte = current, byte != 0x0A, byte != 0x0D else { throw fail("unterminated string") }
            if byte == UInt8(ascii: "'") {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return text
            }
            if isControlByte(byte) && byte != 0x09 { throw fail("control character in string") }
            index += 1
        }
    }

    mutating func parseArray() throws -> [Value] {
        index += 1
        var items: [Value] = []
        while true {
            try skipSpacesNewlinesAndComments()
            guard let byte = current else { throw fail("unterminated array") }
            if byte == UInt8(ascii: "]") { index += 1; return items }
            items.append(try parseValue(inArray: true))
            guard items.count <= Self.maximumArrayItems else { throw fail("array with more than \(Self.maximumArrayItems) items") }
            try skipSpacesNewlinesAndComments()
            guard let separator = current else { throw fail("unterminated array") }
            if separator == UInt8(ascii: ",") { index += 1; continue }
            if separator == UInt8(ascii: "]") { index += 1; return items }
            throw fail("expected ',' or ']' in array")
        }
    }

    mutating func skipSpaces() {
        while let byte = current, byte == 0x20 || byte == 0x09 { index += 1 }
    }

    /// Consumes LF or CRLF. A lone CR is an error.
    mutating func consumeNewline() throws -> Bool {
        if current == 0x0A { index += 1; line += 1; return true }
        if current == 0x0D {
            guard peek(1) == 0x0A else { throw fail("carriage return without a line feed") }
            index += 2; line += 1; return true
        }
        return false
    }

    mutating func skipComment() throws {
        index += 1
        while let byte = current, byte != 0x0A, byte != 0x0D {
            if isControlByte(byte) && byte != 0x09 { throw fail("control character in comment") }
            index += 1
        }
    }

    mutating func skipSpacesNewlinesAndComments() throws {
        while true {
            skipSpaces()
            if try consumeNewline() { continue }
            if current == UInt8(ascii: "#") { try skipComment(); continue }
            return
        }
    }

    /// After a value or a header: spaces, an optional comment, then a newline or the end of the file.
    mutating func expectEndOfLine() throws {
        skipSpaces()
        if current == UInt8(ascii: "#") { try skipComment() }
        if atEnd { return }
        guard try consumeNewline() else { throw fail("unexpected text after the value") }
    }
}

private func isBareKeyByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
}

private func isControlByte(_ byte: UInt8) -> Bool { byte < 0x20 || byte == 0x7F }
