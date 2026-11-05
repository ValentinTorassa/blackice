import Foundation
import Testing
@testable import BlackiceCore

/// The repository's root, from this file's path.
private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

struct AgentInstructionsTests {
    /// What ships inside blackice is what integrations/ holds, byte for byte. When this fails, run
    /// macos/scripts/agent-instructions.sh.
    @Test func theTextIsTheRepositorysFiles() throws {
        let sources: [AgentInstructions: String] = [
            .fx: "integrations/fx/skills/blackice/SKILL.md",
            .claudeCode: "integrations/claude-code/blackice/instructions.md",
            .codex: "integrations/codex/instructions.md",
        ]
        #expect(Set(sources.keys) == Set(AgentInstructions.allCases))
        for (set, source) in sources {
            let file = try String(contentsOf: repository.appendingPathComponent(source), encoding: .utf8)
            #expect(set.files.count == 1 && set.files[0].text == file,
                    "\(source) and AgentInstructionsText.swift differ: run macos/scripts/agent-instructions.sh")
        }
        #expect(AgentInstructions.fx.files.map(\.path) == ["skills/blackice/SKILL.md"])
        #expect(AgentInstructions.claudeCode.files.map(\.path) == ["instructions.md"])
        #expect(AgentInstructions.codex.files.map(\.path) == ["instructions.md"])
    }

    @Test func aProgramHookNamesItsInstructions() throws {
        let text = """
            mode = "ask"
            [[hook]]
            on = "connection"
            program = "/opt/fake/claude"
            app = "com.anthropic.claude-code"
            team = "Q6L2SF6YDW"
            instructions = "claude-code"

            """
        #expect(try BlackiceConfig(text: text).hooks.first?.program?.instructions == .claudeCode)
        #expect(try BlackiceConfig(text: text.replacingOccurrences(of: "instructions = \"claude-code\"\n", with: ""))
            .hooks.first?.program?.instructions == nil)
        #expect(throws: ConfigError(line: 7, "instructions must be \"fx\", \"claude-code\" or \"codex\", not \"mine\"")) {
            try BlackiceConfig(text: text.replacingOccurrences(of: "\"claude-code\"\n", with: "\"mine\"\n"))
        }
        #expect(throws: ConfigError(line: 4, "instructions goes with program, not run")) {
            try BlackiceConfig(text: "mode = \"ask\"\n[[hook]]\non = \"connection\"\ninstructions = \"fx\"\nrun = 'x'\n")
        }
    }

    /// The daemon writes them into the event's directory before the program starts: the program
    /// finds them there by a relative path, 0600 in 0700 folders, and they go with the directory.
    @Test func theRunnerWritesThemBesideTheEvent() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let copy = dir.appendingPathComponent("seen")
        let script = "mkdir \(quotedPath(copy)) && cp -p skills/blackice/SKILL.md \(quotedPath(copy))/ && " +
            "stat -f '%Lp' skills skills/blackice skills/blackice/SKILL.md > \(quotedPath(copy))/modes && ls -A > \(quotedPath(copy))/list; echo deny"
        let program = HookProgram(path: "/bin/sh", arguments: ["-c", script],
                                  identity: SigningIdentity(signingID: "com.apple.sh", teamID: nil), instructions: .fx)
        let results = try await testRunner(dir).run([Hook(program: program, line: 1)], for: testEvent(), timeoutSeconds: 10)
        #expect(results.first?.answer == .success(.deny), "\(String(describing: results.first))")
        #expect(try String(contentsOf: copy.appendingPathComponent("SKILL.md"), encoding: .utf8) == AgentInstructionsText.fx)
        #expect(try String(contentsOf: copy.appendingPathComponent("modes"), encoding: .utf8) == "700\n700\n600\n")
        #expect(try String(contentsOf: copy.appendingPathComponent("list"), encoding: .utf8) == "event.json\nskills\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("work").path).isEmpty)
    }

    @Test func onlyPlainRelativePaths() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        for path in ["/etc/x", "../x", "a/../../x", "./x", ""] {
            #expect(throws: FileSafetyError.self, "\(path)") { try writeAgentFiles([AgentFile(path: path, text: "x")], into: dir) }
        }
        try writeAgentFiles([AgentFile(path: "a/b.md", text: "x")], into: dir)
        // Nothing is written over: a second write of the same file fails.
        #expect(throws: FileSafetyError.self) { try writeAgentFiles([AgentFile(path: "a/b.md", text: "y")], into: dir) }
        #expect(try String(contentsOf: dir.appendingPathComponent("a/b.md"), encoding: .utf8) == "x")
    }
}
