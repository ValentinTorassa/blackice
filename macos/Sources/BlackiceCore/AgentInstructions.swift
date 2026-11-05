import Darwin
import Foundation

// The instructions each deciding agent gets, shipped inside blackice. Up to 0.4.0, `agent connect`
// copied them into the agent's home, where any program of the user could rewrite them, and with
// them what the agent answers. Now a `program` hook names its set (`instructions = "fx"`), and
// the daemon writes the files into the event's private directory before it starts the program,
// for each event. The hook names them by a path relative to that directory, its working
// directory. The text is in AgentInstructionsText.swift, which macos/scripts/agent-instructions.sh
// writes from integrations/; a test fails when the two drift.

/// One file the daemon writes into an event's directory.
public struct AgentFile: Equatable, Sendable {
    /// Relative to the event's directory, with no `..`.
    public let path: String
    public let text: String
}

/// A set of instructions, by the agent it is for.
public enum AgentInstructions: String, CaseIterable, Sendable {
    case fx
    case claudeCode = "claude-code"
    case codex
    case opencode

    /// What the daemon writes. fx reads skills from its workspace's `skills/` folder; Claude Code
    /// gets `--system-prompt-file instructions.md`, Codex `-c model_instructions_file="instructions.md"`,
    /// opencode an agent whose prompt is `{file:./instructions.md}`.
    public var files: [AgentFile] {
        switch self {
        case .fx: return [AgentFile(path: "skills/blackice/SKILL.md", text: AgentInstructionsText.fx)]
        case .claudeCode: return [AgentFile(path: "instructions.md", text: AgentInstructionsText.claudeCode)]
        case .codex: return [AgentFile(path: "instructions.md", text: AgentInstructionsText.codex)]
        case .opencode: return [AgentFile(path: "instructions.md", text: AgentInstructionsText.opencode)]
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

    /// "fx", "claude-code" or …, for messages.
    public static var names: String {
        let quoted = allCases.map { "\"\($0.rawValue)\"" }
        return quoted.count <= 1 ? quoted.joined() : quoted.dropLast().joined(separator: ", ") + " or " + quoted.last!
    }
}

/// Writes `files` into `directory`, which the caller just created: each file 0600, each folder on
/// the way 0700, none of them there before (O_EXCL, and mkdir fails on what exists).
func writeAgentFiles(_ files: [AgentFile], into directory: URL) throws {
    for file in files {
        let parts = file.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !file.path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else {
            throw FileSafetyError(file.path, "is not a plain relative path")
        }
        var folder = directory
        for part in parts.dropLast() {
            folder.appendPathComponent(part, isDirectory: true)
            guard mkdir(folder.path, 0o700) == 0 else {
                throw FileSafetyError(folder.path, "cannot create the folder: \(errnoText(errno))")
            }
        }
        try writePrivateFile(folder.appendingPathComponent(parts.last!), Data(file.text.utf8))
    }
}

/// Creates the file with mode 0600, refusing one that exists or a symlink.
func writePrivateFile(_ url: URL, _ data: Data) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileSafetyError(url.path, "cannot create the file: \(errnoText(errno))") }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw FileSafetyError(url.path, "cannot set mode 0600: \(errnoText(errno))") }
    try writeAll(fd, data, path: url.path)
}

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
