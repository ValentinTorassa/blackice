import Darwin
import Foundation

// The instructions each deciding agent gets, shipped inside blackice. Up to 0.4.0, `agent connect`
// copied them into the agent's home, and up to 1.0.2 the daemon wrote them into the event's
// directory for each event, next to event.json and notes.md. Any program of the user could rewrite
// those files while the agent read them, and with them what the agent answers. Since 1.0.3 a
// `program` hook that names its set (`instructions = "codex"`) gets no files at all: the runner
// puts the instructions and the owner's notes in the agent's own flags or environment (`launch`),
// the event goes on stdin, and the agent runs in /var/empty. The text is in
// AgentInstructionsText.swift, which macos/scripts/agent-instructions.sh writes from integrations/;
// a test fails when the two drift.

/// A set of instructions, by the agent it is for.
public enum AgentInstructions: String, CaseIterable, Sendable {
    case fx
    case claudeCode = "claude-code"
    case codex
    case opencode

    /// The instructions as the agent gets them: the file in integrations/, and for fx its skill
    /// without the front matter, which fx needs only to find a skill in a folder.
    public var text: String {
        switch self {
        case .fx: return Self.droppingFrontMatter(AgentInstructionsText.fx)
        case .claudeCode: return AgentInstructionsText.claudeCode
        case .codex: return AgentInstructionsText.codex
        case .opencode: return AgentInstructionsText.opencode
        }
    }

    /// The agent's name for people: "fx", "Claude Code", "Codex", "opencode".
    public var title: String {
        switch self {
        case .fx: return "fx"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        }
    }

    /// Whether the menu's Mode and the first start's list show this agent before it is connected.
    /// Codex and opencode are left out of both for now (decided 5 November 2026), to keep them
    /// short: `blackice agent connect codex|opencode` and `blackice mode ask --agent` still take
    /// them, and the menu lists one once its hook is in the configuration.
    public var listedBeforeConnecting: Bool {
        switch self {
        case .fx, .claudeCode: return true
        case .codex, .opencode: return false
        }
    }

    /// "fx", "claude-code" or …, for messages.
    public static var names: String {
        let quoted = allCases.map { "\"\($0.rawValue)\"" }
        return quoted.count <= 1 ? quoted.joined() : quoted.dropLast().joined(separator: ", ") + " or " + quoted.last!
    }

    /// The text after a `---` front matter block and the blank lines that follow it.
    static func droppingFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...].drop { $0 == "\n" })
    }
}

// MARK: - What the hook runs

extension AgentInstructions {
    /// What the hook asks the agent, the last of its `args`; nil for fx, whose prompt is the event
    /// itself: `fx ask` reads its prompt from stdin only when no prompt is given.
    public var prompt: String? {
        switch self {
        case .fx: return nil
        case .claudeCode:
            return "Decide the pending blackice connection. Its event is the JSON object in this message, which blackice sent on stdin."
        case .codex: return "Decide the pending blackice connection. Its event is the JSON object in the <stdin> block below."
        case .opencode:
            return "Decide whether to approve the pending blackice connection. Its event is the JSON object in this message, which blackice sent on stdin."
        }
    }

    /// The `args` `blackice agent connect` writes for this agent and model, checked against Claude
    /// Code 2.1.318, Codex 0.166.0, opencode 2.2.5 and fx 0.0.16. The runner adds the instructions
    /// and the owner's notes (`launch`).
    /// - Claude Code: print mode with no tools at all (`--tools ""`): the event comes in the prompt,
    ///   and there is nothing to read. --restricted ignores the user, project and local settings and
    ///   keeps file tools in the working directory; --safe-mode turns off CLAUDE.md, skills, plugins
    ///   and hooks; no MCP server, nothing saved, plain text whose last line is the answer.
    /// - Codex: one `codex exec`. Nothing of yours: no config.toml, rules, AGENTS.md from the working
    ///   directory, skills list, hooks, plugins, apps, subagents, image generation, browser or
    ///   computer use, web search, session or history. Its commands run in a sandbox that reads only
    ///   the system's own files and the working directory (`:minimal`), writes nothing and has no
    ///   network; nothing asks for approval. `--strict-config` refuses a key it does not know.
    /// - opencode: one `opencode run` with a server of its own, as the blackice agent that the
    ///   configuration the runner puts in its environment defines.
    /// - fx: one `fx ask`, nothing saved, plain Markdown with no colors.
    /// integrations/eval/agents/NAME.sh runs the same (a test checks).
    public func hookArguments(model: String) -> [String] {
        switch self {
        case .fx:
            return ["ask", "--no-save", "--no-color", "--model", model]
        case .claudeCode:
            return ["-p", "--restricted", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                    "--permission-prompts", "none", "--model", model, "--max-turns", "3", "--output-format", "text", prompt!]
        case .codex:
            return ["exec", "--strict-config", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "--color", "never", "-m", model] + Self.codexSettings(instructionsFile: nil) + Self.codexFeatures + [prompt!]
        case .opencode:
            return ["run", "--standalone", "--agent", "blackice", "--model", model, prompt!]
        }
    }

    private static func codexSettings(instructionsFile: String?) -> [String] {
        var settings = ["model_reasoning_effort=\"low\""]
        if let instructionsFile { settings.append("model_instructions_file=\"\(instructionsFile)\"") }
        settings.append("project_doc_max_bytes=0")
        // Codex lists the skills in CODEX_HOME in its prompt, names and descriptions, and any
        // program of the user can add one there.
        if instructionsFile == nil { settings.append("skills.include_instructions=false") }
        settings += ["default_permissions=\"blackice\"",
                     "permissions.blackice.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\"}",
                     "approval_policy=\"never\"", "allow_login_shell=false", "web_search=\"disabled\"",
                     "analytics.enabled=false", "feedback.enabled=false", "history.persistence=\"none\""]
        return settings.flatMap { ["-c", $0] }
    }

    private static let codexFeatures = ["hooks", "plugins", "apps", "multi_agent", "image_generation", "browser_use", "computer_use"]
        .flatMap { ["--disable", $0] }

    /// What the hook asked from 0.4.1 to 1.0.2, when the event and the instructions were files in
    /// its working directory. A hook from before 0.4.1, which names no instructions, is known by it.
    public var filedPrompt: String {
        switch self {
        case .fx: return "Use the blackice skill to decide whether to approve the pending connection"
        case .claudeCode: return "Decide the pending blackice connection in event.json."
        case .codex: return "Decide the pending blackice connection described in event.json."
        case .opencode: return "Decide whether to approve the pending blackice connection in event.json."
        }
    }

    /// The `args` `agent connect` wrote from 0.4.2 to 1.0.2, and from 0.4.1 for fx, whose hook had
    /// no `--system` until 0.4.2 (the others were the same from their first release to 1.0.2).
    func filedArgumentSets(model: String) -> [[String]] {
        let current = filedArguments(model: model)
        guard self == .fx else { return [current] }
        return [current, ["ask", "--no-save", "--no-color", "--model", model, filedPrompt]]
    }

    /// The `args` `agent connect` wrote from 0.4.2 to 1.0.2.
    func filedArguments(model: String) -> [String] {
        switch self {
        case .fx:
            return ["ask", "--no-save", "--no-color", "--model", model, "--system",
                    "You answer for blackice, a network filter on a Mac: one app wants to reach one host, and you decide whether to approve it. The blackice skill in this workspace says how to read the event and how to answer. Follow it exactly and answer in its format.",
                    filedPrompt]
        case .claudeCode:
            return ["-p", "--restricted", "--safe-mode", "--tools", "Read", "--strict-mcp-config", "--no-session-persistence",
                    "--permission-prompts", "none", "--model", model, "--max-turns", "3", "--output-format", "text",
                    "--system-prompt-file", "instructions.md", filedPrompt]
        case .codex:
            return ["exec", "--strict-config", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "--color", "never", "-m", model] + Self.codexSettings(instructionsFile: "instructions.md") + Self.codexFeatures
                + [filedPrompt]
        case .opencode:
            return ["run", "--standalone", "--agent", "blackice", "--model", model, filedPrompt]
        }
    }

    /// The hook's `args`, with those `agent connect` wrote up to 1.0.2 replaced by what it writes
    /// now for the same model, so that a blackice.toml from 1.0 keeps working: those named files
    /// that are no longer written. Any other `args` are left as they are.
    public func upgraded(_ arguments: [String]) -> [String] {
        let flag = self == .codex ? "-m" : "--model"
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return arguments }
        let model = arguments[index + 1]
        return filedArgumentSets(model: model).contains(arguments) ? hookArguments(model: model) : arguments
    }
}

// MARK: - How the instructions reach the agent

/// What the runner starts an agent's program with: its `args` with the instructions and the
/// owner's notes in the agent's own flags, and the variables it sets on top of the hook's `env`.
public struct AgentLaunch: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: String]
}

extension AgentInstructions {
    /// The owner's notes as the agent gets them, after its instructions.
    public static func notesSection(_ notes: String) -> String {
        "## The owner's notes\n\n" + notes + (notes.hasSuffix("\n") ? "" : "\n")
    }

    /// The instructions and the notes in one text, for the agents that take one.
    public func systemPrompt(notes: String?) -> String {
        text + (notes.map { "\n" + Self.notesSection($0) } ?? "")
    }

    /// Whether the agent needs a folder of its own for each event: opencode creates its global
    /// configuration folder, `opencode/` in XDG_CONFIG_HOME, and stops when it cannot (/var/empty).
    public var needsConfigurationFolder: Bool { self == .opencode }

    /// How the runner starts this agent: its `args` (upgraded from before 1.0.3), without the flags
    /// that carry instructions, which are blackice's here; then the instructions and the notes
    /// where the agent takes them:
    /// - Claude Code: `--system-prompt` and `--append-system-prompt` (the notes), first;
    /// - Codex: `-c developer_instructions="…"` right after `exec`, a TOML string;
    /// - opencode: the prompt of the blackice agent in OPENCODE_CONFIG_CONTENT, and XDG_CONFIG_HOME;
    /// - fx: `--system` right after `ask`, which replaces fx's own system prompt.
    /// `configurationFolder` is opencode's XDG_CONFIG_HOME. All of it together stays far below
    /// ARG_MAX (1 MiB): about 10 KB of instructions and at most 4 KiB of notes.
    public func launch(arguments configured: [String], notes: String?, configurationFolder: String? = nil) -> AgentLaunch {
        var arguments = Self.removing(ownedFlags, from: upgraded(configured))
        switch self {
        case .claudeCode:
            let notesFlags = notes.map { ["--append-system-prompt", Self.notesSection($0)] } ?? []
            arguments = ["--system-prompt", text] + notesFlags + arguments
            return AgentLaunch(arguments: arguments, environment: [:])
        case .codex:
            let at = ["exec", "e"].contains(arguments.first) ? 1 : 0
            arguments.insert(contentsOf: ["-c", "developer_instructions=" + Self.tomlString(systemPrompt(notes: notes))], at: at)
            return AgentLaunch(arguments: arguments, environment: [:])
        case .fx:
            let at = arguments.first == "ask" ? 1 : 0
            arguments.insert(contentsOf: ["--system", systemPrompt(notes: notes)], at: at)
            return AgentLaunch(arguments: arguments, environment: [:])
        case .opencode:
            var environment = ["OPENCODE_CONFIG_CONTENT": Self.openCodeConfiguration(prompt: systemPrompt(notes: notes))]
            if let configurationFolder { environment["XDG_CONFIG_HOME"] = configurationFolder }
            return AgentLaunch(arguments: arguments, environment: environment)
        }
    }

    /// The flags that carry instructions to the agent, which the runner sets itself; each takes a
    /// value. For Codex, the `-c` settings whose key names instructions.
    private var ownedFlags: (flags: Set<String>, settings: [String]) {
        switch self {
        case .claudeCode:
            return (["--system-prompt", "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file"], [])
        case .codex:
            return ([], ["developer_instructions", "model_instructions_file", "experimental_instructions_file", "instructions"])
        case .fx:
            return (["--system"], [])
        case .opencode:
            return ([], [])
        }
    }

    private static func removing(_ owned: (flags: Set<String>, settings: [String]), from arguments: [String]) -> [String] {
        func ownedSetting(_ text: Substring) -> Bool {
            owned.settings.contains { text.hasPrefix($0 + "=") || text.hasPrefix($0 + " =") }
        }
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let name = String(argument.prefix { $0 != "=" })
            if owned.flags.contains(argument) {
                index += 2
            } else if argument.hasPrefix("--"), argument.contains("="), owned.flags.contains(name) {
                index += 1
            } else if ["-c", "--config"].contains(argument), arguments.indices.contains(index + 1),
                      ownedSetting(Substring(arguments[index + 1])) {
                index += 2
            } else if argument.hasPrefix("--config="), ownedSetting(argument.dropFirst("--config=".count)) {
                index += 1
            } else {
                kept.append(argument)
                index += 1
            }
        }
        return kept
    }

    /// A TOML basic string, which Codex parses the value of `-c` as: quotes and backslashes
    /// escaped, and every control character, line breaks included, as an escape.
    public static func tomlString(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case "\r": quoted += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    /// The configuration opencode gets in OPENCODE_CONFIG_CONTENT, which comes after its global and
    /// project files and so wins over them: an agent whose whole system prompt is `prompt`, with a
    /// few steps and no tool at all, for every agent and for this one, each tool named, since a
    /// file's rule for one would otherwise stay; no update check and no sharing. opencode replaces
    /// `{env:…}` and `{file:…}` in it, so those are broken up first: the notes could hold one.
    public static func openCodeConfiguration(prompt: String) -> String {
        let rules = openCodeTools.map { "\"\($0)\":\"deny\"" }.joined(separator: ",")
        let safe = prompt.replacingOccurrences(of: "{env:", with: "{ env:").replacingOccurrences(of: "{file:", with: "{ file:")
        return "{\"agent\":{\"blackice\":{\"mode\":\"primary\",\"prompt\":\(jsonString(safe)),\"steps\":4,"
            + "\"permission\":{\(rules)}}},\"autoupdate\":false,\"permission\":{\(rules)},\"share\":\"disabled\"}"
    }

    static let openCodeTools = ["*", "read", "bash", "edit", "glob", "grep", "task", "todowrite", "skill", "lsp", "question",
                                "webfetch", "websearch", "external_directory", "doom_loop"]

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

// MARK: - What the agent loads from its home

extension AgentInstructions {
    /// A file in the agent's home that it would load as instructions whatever its flags say, which
    /// blackice did not put there; nil when there is none. `environment` is the hook's, HOME and its
    /// `env` included. Up to 1.0.2 nothing checked this: Codex reads CODEX_HOME/AGENTS.md and
    /// AGENTS.override.md as global instructions, and fx reads its own AGENTS.md, its skills and
    /// the skills of other agents in HOME, and takes its rules and model provider from its
    /// settings, all in folders any program of the user can write to. Claude Code ignores all of
    /// its own with --restricted and --safe-mode, and opencode gets a new configuration folder for
    /// each event. The runner looks before it starts the hook and again once it exits, so a file
    /// added while it runs voids its answer; a file added and removed in between goes unseen.
    public func plantedFile(environment: [String: String]) -> String? {
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        switch self {
        case .claudeCode, .opencode:
            return nil
        case .codex:
            guard let codexHome = environment["CODEX_HOME"].flatMap({ $0.hasPrefix("/") ? $0 : nil }) ?? home.map({ $0 + "/.codex" })
            else { return nil }
            for name in ["AGENTS.override.md", "AGENTS.md"] where Self.exists(codexHome + "/" + name) {
                return codexHome + "/" + name
            }
            // Skills are kept out of its prompt (skills.include_instructions=false), but a folder
            // there that Codex did not make (it makes .system) means someone else writes there.
            return Self.entries(codexHome + "/skills").first { $0 != ".system" }.map { codexHome + "/skills/" + $0 }
        case .fx:
            guard let home else { return nil }
            let folder = environment["FX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.fx"
            if Self.exists(folder + "/AGENTS.md") { return folder + "/AGENTS.md" }
            // fx 0.0.16's skill folders: its own, then those of other agents in HOME. Each skill is a
            // folder with a SKILL.md in it.
            let roots = [folder + "/skills"] + [".config/opencode/skills", ".codex/skills", ".claude/skills", ".agents/skills",
                                                ".claw/skills"].map { home + "/" + $0 }
            for root in roots {
                for entry in Self.entries(root) where Self.exists(root + "/" + entry + "/SKILL.md") {
                    return root + "/" + entry + "/SKILL.md"
                }
            }
            return Self.fxSettingsChanged(folder + "/settings.json")
        }
    }

    /// fx's settings, which `agent connect` writes with rules that leave it no shell, no edits and
    /// no web: the file, when they are not those rules any more, or it sends the model's requests
    /// somewhere else (another provider, a provider of its own, or settings for one workspace).
    static func fxSettingsChanged(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return exists(path) ? path : nil }
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return path }
        let rules = settings["permission"] as? [String: [String: String]]
        let denied = ["bash", "edit", "web_fetch", "web_search"].reduce(into: [String: [String: String]]()) { $0[$1] = ["*": "deny"] }
        guard settings["permission_mode"] as? String == "ask", rules == denied, settings["providers"] == nil,
              settings["workspaces"] == nil, settings["provider"] == nil || settings["provider"] as? String == "gateway"
        else { return path }
        return nil
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// The names in a folder, sorted; none when it is missing or cannot be read.
    static func entries(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }
}

// MARK: - Files for `run` hooks

/// Creates the file with mode 0600, refusing one that exists or a symlink.
func writePrivateFile(_ url: URL, _ data: Data) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileSafetyError(url.path, "cannot create the file: \(errnoText(errno))") }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw FileSafetyError(url.path, "cannot set mode 0600: \(errnoText(errno))") }
    try writeAll(fd, data, path: url.path)
}

// MARK: - Who answers

/// Who answers the connections that wait in ask mode: one agent, through its hook, or you, from the
/// menu or with `blackice approve` and `deny`. `answers` in [agent] names it ("fx", "claude-code",
/// "codex", "opencode" or "you").
public enum Answerer: Hashable, Sendable {
    case agent(AgentInstructions)
    case you

    public init?(name: String) {
        if name == "you" {
            self = .you
        } else if let instructions = AgentInstructions(rawValue: name) {
            self = .agent(instructions)
        } else {
            return nil
        }
    }

    /// As blackice.toml and `--agent` spell it.
    public var name: String {
        switch self {
        case .agent(let instructions): return instructions.rawValue
        case .you: return "you"
        }
    }

    /// "Claude Code", "you".
    public var title: String {
        switch self {
        case .agent(let instructions): return instructions.title
        case .you: return "you"
        }
    }

    /// Every agent blackice knows, then you.
    public static var all: [Answerer] { AgentInstructions.allCases.map { .agent($0) } + [.you] }

    /// "fx", "claude-code", "codex", "opencode" or "you", for messages.
    public static var names: String {
        let quoted = all.map { "\"\($0.name)\"" }
        return quoted.dropLast().joined(separator: ", ") + " or " + quoted.last!
    }
}

/// Who answers under one configuration, as the menu and `blackice status` show it.
public struct Answering: Equatable, Sendable {
    /// The agents with a hook in the configuration (one that names its `instructions`), in the
    /// order of their hooks.
    public let agents: [AgentInstructions]
    /// Who answers: the one `answers` names; with no `answers`, the one agent with a hook, or you
    /// when none has one. nil when several agents have hooks and `answers` names none: they all run.
    public let answerer: Answerer?

    public init(agents: [AgentInstructions], answerer: Answerer?) {
        self.agents = agents
        self.answerer = answerer
    }
}
