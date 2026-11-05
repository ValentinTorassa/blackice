import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

/// A Mac with fx at /opt/fake/fx: `status` says signed in once `login` ran, and the hook "decides"
/// by printing what fx would print, its answer last.
private final class FakeAgentMac: @unchecked Sendable {
    var signedIn: Bool
    var hookStderr = "fx: done"
    var hookOutcome = HookResult.Outcome.exited(status: 0)
    var loginFailures = 0
    var installed = true
    var installs: [[String]] = []
    var answer: ((HookEvent) -> String)?
    var logins: [[String: String]] = []
    var hookRuns: [Hook] = []
    var events: [HookEvent] = []
    var notes: [String?] = []
    /// Runs while fx decides the sample event, as a person editing blackice.toml meanwhile would.
    var duringTest: (() -> Void)?
    /// Control-C pressed while fx signs in or decides the sample event; fx dies of it.
    enum Wait { case signIn, test }
    var controlC: Wait?
    /// Whether Control-C was caught, and how often the signals were caught and released.
    var interrupted = false
    var catches = 0
    var releases = 0

    init(signedIn: Bool, answer: ((HookEvent) -> String)?) {
        self.signedIn = signedIn
        self.answer = answer
    }

    var machine: AgentMachine {
        AgentMachine(
            findExecutable: { $0 == "fx" && self.installed ? "/opt/fake/fx" : nil },
            runAttached: { path, arguments, environment in
                if arguments == ["login", "vercel"] {
                    self.logins.append(environment)
                    if self.controlC == .signIn { self.interrupted = true; return 128 + SIGINT }
                    if self.loginFailures > 0 { self.loginFailures -= 1; return 1 }
                    self.signedIn = true
                }
                if path == "/bin/bash" { self.installs.append(arguments); self.installed = arguments.last?.contains("fx.sh") == true }
                return 0
            },
            runCaptured: { _, arguments, _ in
                (0, arguments == ["status"] ? "[status] model=x\n[status] auth=\(self.signedIn ? "vercel" : "missing")\n" : "")
            },
            runHook: { hook, event, notes, _, _ in
                self.hookRuns.append(hook)
                self.events.append(event)
                self.notes.append(notes)
                self.duringTest?()
                if self.controlC == .test {
                    self.interrupted = true
                    return HookResult(hookLine: 0, outcome: .signaled(signal: SIGTERM), stderr: "", stderrTruncated: false,
                                      duration: 3)
                }
                return HookResult(hookLine: 0, outcome: self.hookOutcome, stderr: self.hookStderr, stderrTruncated: false,
                                  duration: 14, stdout: Data((self.answer?(event) ?? "").utf8))
            },
            catchInterrupts: { self.catches += 1; return { self.releases += 1 } },
            interrupted: { self.interrupted })
    }
}

/// A Mac with Claude Code at /opt/fake/claude: `auth status --json` says signed in once
/// `auth login` ran, and the hook "decides" by printing `printed`.
private final class FakeClaudeMac: @unchecked Sendable {
    var signedIn: Bool
    var printed: String
    var status: Int32 = 0
    var logins: [[String: String]] = []
    var hookRuns: [Hook] = []

    init(signedIn: Bool, printed: String) {
        self.signedIn = signedIn
        self.printed = printed
    }

    var machine: AgentMachine {
        AgentMachine(
            findExecutable: { $0 == "claude" ? "/opt/fake/claude" : nil },
            runAttached: { _, arguments, environment in
                if arguments == ["auth", "login"] { self.logins.append(environment); self.signedIn = true }
                return 0
            },
            runCaptured: { _, arguments, _ in
                arguments == ["auth", "status", "--json"]
                    ? (self.signedIn ? 0 : 1, "{\n  \"loggedIn\": \(self.signedIn),\n  \"authMethod\": \"claude.ai\"\n}\n") : (0, "")
            },
            runHook: { hook, _, _, _, _ in
                self.hookRuns.append(hook)
                return HookResult(hookLine: 0, outcome: .exited(status: self.status), stderr: "", stderrTruncated: false,
                                  duration: 6, stdout: Data(self.printed.utf8))
            })
    }
}

/// Loads what it is given and keeps the mode saved. `startStatuses` and `modeStatuses` answer the
/// calls in turn (0 once they run out); a call that fails changes nothing, as with Touch ID cancelled.
private final class Loading: SystemControlling {
    var texts: [String] = []
    var nexts: [Bool] = []
    var agentInstalls = 0
    var running: Mode?
    var modes: [Mode] = []
    var startStatuses: [Int32] = []
    var modeStatuses: [Int32] = []
    func start(configText: String, output: SystemOutput) -> Int32 {
        texts.append(configText); nexts.append(output.next)
        let status = startStatuses.isEmpty ? 0 : startStatuses.removeFirst()
        guard status == 0 else { return status }
        running = try? BlackiceConfig(text: configText).mode
        output.stdout("(started)")
        return 0
    }
    func stop(output: SystemOutput) -> Int32 { 0 }
    func status(output: SystemOutput) -> Int32 { 0 }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 {
        modes.append(mode)
        let status = modeStatuses.isEmpty ? 0 : modeStatuses.removeFirst()
        if status == 0 { running = mode }
        return status
    }
    func runningMode() -> Mode? { running }
    func pending(output: SystemOutput) -> Int32 { 0 }
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { 0 }
    func runDaemon(output: SystemOutput) -> Int32 { 0 }
    func installAgent(output: SystemOutput) -> Int32 { agentInstalls += 1; return 0 }
    func uninstallAgent(output: SystemOutput) -> Int32 { 0 }
}

private struct Connected {
    let status: Int32
    let stdout: [String]
    let stderr: [String]
}

struct AgentConnectTests {
    static let fx = SigningIdentity(signingID: "com.vercel.fx", teamID: "JW6Y669B67")
    static let approve: @Sendable (HookEvent) -> String = { _ in
        "I read event.json.\n\nVisual Studio Code, signed by Microsoft, reaching its own update server.\n\napprove 1h\n"
    }
    static func agent(_ home: URL) -> String { home.path + "/.config/blackice/agent" }
    static func program(_ home: URL) -> HookProgram {
        HookProgram(path: "/opt/fake/fx", arguments: ["ask", "--no-save", "--no-color", AgentProfile.prompt],
                    environment: ["HOME": agent(home), "FX_DISABLE_KEYCHAIN": "1"], identity: fx, instructions: .fx)
    }

    /// A home with blackice.toml.
    private func setUp(_ config: String) throws -> (home: URL, config: String) {
        let home = try makePrivateDirectory()
        let folder = home.appendingPathComponent(".config/blackice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("blackice.toml").path
        try Data(config.utf8).write(to: URL(fileURLWithPath: path))
        return (home, path)
    }

    /// An answer that stands for Control-C at the question: no line, and the signal caught.
    static let controlC = "^C"

    private func connect(_ home: URL, config: String, mac: FakeAgentMac, system: Loading, answers: [String] = [],
                         arguments: [String]? = nil) -> Connected {
        var script = answers
        let interaction = Interaction(
            ask: { _ in
                guard !script.isEmpty else { return nil }
                let answer = script.removeFirst()
                if answer == Self.controlC { mac.interrupted = true; return nil }
                return answer
            }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/fx" ? Self.fx : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(arguments ?? ["agent", "connect", "fx", "--config", config], stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: system, interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    static let claude = SigningIdentity(signingID: "com.anthropic.claude-code", teamID: "Q6L2SF6YDW")
    static func claudeProgram(_ home: URL) -> HookProgram {
        HookProgram(path: "/opt/fake/claude", arguments: CLI.claudeCodeArguments(),
                    environment: ["CLAUDE_CONFIG_DIR": agent(home) + "/.claude", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"],
                    identity: claude, eventOnStdin: false, instructions: .claudeCode)
    }
    static let claudeApproves = "Checking the event.\n\ncom.microsoft.VSCode -> update.code.visualstudio.com: its update server\napprove 1h\n"

    private func connectClaude(_ home: URL, config: String, mac: FakeClaudeMac, system: Loading) -> Connected {
        let interaction = Interaction(
            ask: { _ in nil }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/claude" ? Self.claude : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["agent", "connect", "claude-code", "--config", config], stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: system, interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    /// Claude Code in place of fx: its own configuration directory and sign-in, no settings file,
    /// a program hook with no event on stdin that takes the place of fx's, and only the host its
    /// earlier rule lacked. Then fx again, in place of Claude Code: one agent answers.
    @Test func connectsClaudeCodeInPlaceOfFx() throws {
        let (home, config) = try setUp("""
            mode = "ask"
            timeout_seconds = 10

            [[allow]]
            app = "com.anthropic.claude-code"
            team = "Q6L2SF6YDW"
            hosts = ["*.anthropic.com", "bridge.claudeusercontent.com"]

            [[hook]]
            on = "connection"
            program = "/opt/fake/fx"
            app = "com.vercel.fx"
            team = "JW6Y669B67"
            args = ["ask", "--no-save", "--no-color", "\(AgentProfile.prompt)"]
            """)
        defer { removeTree(home) }
        // The copies of the instructions that 0.4.0 put in the agent home.
        let agent = Self.agent(home)
        let oldCopies = [agent + "/.claude/blackice/instructions.md", agent + "/.fx/skills/blackice/SKILL.md"]
        for file in oldCopies {
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data("# approve everything\n".utf8).write(to: URL(fileURLWithPath: file))
        }
        let mac = FakeClaudeMac(signedIn: false, printed: Self.claudeApproves)
        let system = Loading()
        let result = connectClaude(home, config: config, mac: mac, system: system)
        #expect(result.status == 0, "\(result.stderr)")

        // Nothing in its home says how to decide: the hook names the instructions blackice writes.
        for file in oldCopies { #expect(!FileManager.default.fileExists(atPath: (file as NSString).deletingLastPathComponent)) }
        #expect(FileManager.default.fileExists(atPath: agent + "/.fx/skills"))
        #expect(result.stdout.contains("  ✓ Removed the copies of the instructions earlier versions put in ~/.config/blackice/agent"))
        #expect(!FileManager.default.fileExists(atPath: agent + "/.claude/settings.json"))
        #expect(mac.logins == [["CLAUDE_CONFIG_DIR": agent + "/.claude", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]])
        for folder in [agent, agent + "/.claude"] { #expect(try permissions(URL(fileURLWithPath: folder)) == 0o700) }
        #expect(!FileManager.default.fileExists(atPath: agent + "/test"))

        // The test ran the hook as the file now holds it, in place of fx's, on the same line.
        #expect(mac.hookRuns == [Hook(program: Self.claudeProgram(home), line: 0)])
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.mode == .ask && loaded.timeoutSeconds == 60)
        #expect(loaded.hooks.map(\.program) == [Self.claudeProgram(home)] && loaded.hooks[0].line == 9)
        #expect(written.contains("program = \"/opt/fake/claude\"\napp = \"com.anthropic.claude-code\"\nteam = \"Q6L2SF6YDW\"\n"))
        #expect(written.contains("stdin = \"none\"\ninstructions = \"claude-code\"\n") && !written.contains("com.vercel.fx"))
        #expect(loaded.allow.count == 2 && loaded.allow.last?.hosts.map(\.source) == ["platform.claude.com"])
        for host in AgentProfile.claudeCode.hosts { #expect(loaded.allowRule(for: Self.claude, host: host) != nil) }
        #expect(system.texts == [written] && system.modes.isEmpty)

        #expect(result.stdout.contains("  ✓ /opt/fake/claude is com.anthropic.claude-code, team Q6L2SF6YDW"))
        #expect(result.stdout.contains("  ✓ Its hook gives it one tool, reading the event: no shell, no web, no MCP servers"))
        #expect(result.stdout.contains("  ✓ claude-code approved it in 6 s"))
        #expect(result.stdout.contains("    platform.claude.com"))
        #expect(result.stdout.contains("  ✓ The hook on line 9 ran fx; it now starts claude-code instead,"))

        // Again: nothing changes.
        let again = connectClaude(home, config: config, mac: mac, system: system)
        #expect(again.status == 0, "\(again.stderr)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written && mac.logins.count == 1)
        #expect(again.stdout.contains { $0.hasPrefix("  A hook already starts claude-code (line 9)") })

        // fx in place of Claude Code.
        let back = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                           system: system)
        #expect(back.status == 0, "\(back.stderr)")
        let fxConfig = try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config)))
        #expect(fxConfig.hooks.map(\.program) == [Self.program(home)] && fxConfig.hooks[0].line == 9)
        #expect(back.stdout.contains("  ✓ The hook on line 9 ran claude-code; it now starts fx instead,"))
    }

    /// With two agents' hooks, the first becomes the agent's and the other goes.
    @Test func aSecondAgentHookGoes() throws {
        let (home, config) = try setUp("""
            mode = "ask"
            timeout_seconds = 60

            [[hook]]
            on = "connection"
            run = 'fx ask "\(AgentProfile.prompt)"'

            [[allow]]
            app = "com.apple.curl"
            hosts = ["pypi.org"]

            [[hook]]
            on = "connection"
            program = "/opt/fake/claude"
            app = "com.anthropic.claude-code"
            team = "Q6L2SF6YDW"
            args = ["-p", "\(CLI.claudeCodePrompt)"]
            """)
        defer { removeTree(home) }
        let result = connectClaude(home, config: config, mac: FakeClaudeMac(signedIn: true,
                                                                            printed: Self.claudeApproves), system: Loading())
        #expect(result.status == 0, "\(result.stderr)")
        let loaded = try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config)))
        #expect(loaded.hooks.map(\.program) == [Self.claudeProgram(home)] && loaded.hooks[0].line == 4)
        #expect(loaded.allow.map(\.app) == ["com.apple.curl", "com.anthropic.claude-code"])
        #expect(result.stdout.contains("  ✓ The hook on line 4 ran fx; it now starts claude-code instead,"))
        #expect(result.stdout.contains("  ✓ The hook on line 12, which ran claude-code, is gone: one agent answers"))
    }

    @Test func claudeCodeWithoutAnAnswerLeavesTheFileAlone() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        // Signed in for `auth status`, but not in the hook's environment (ANTHROPIC_API_KEY in the shell).
        let unsigned = FakeClaudeMac(signedIn: true, printed: "Not logged in · Please run /login\n")
        unsigned.status = 1
        let refused = connectClaude(home, config: config, mac: unsigned, system: Loading())
        #expect(refused.status == ExitCode.software)
        #expect(refused.stderr.first == "  claude-code exited with status 1 and gave no answer, so blackice.toml was left as it was.")
        #expect(refused.stderr.contains("    Not logged in · Please run /login"))
        #expect(refused.stderr.contains("  CLAUDE_CONFIG_DIR=~/.config/blackice/agent/.claude claude auth login"))
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)
    }

    @Test func claudeCodePieces() throws {
        #expect(CLI.claudeCodeSignedIn("{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"))
        #expect(CLI.claudeCodeSignedIn("A notice first\n{\"loggedIn\": true}\n"))
        #expect(!CLI.claudeCodeSignedIn("{\"loggedIn\": false}") && !CLI.claudeCodeSignedIn("Not logged in") && !CLI.claudeCodeSignedIn(""))

        // Read is its only tool, and the hook goes into blackice.toml and back as it was.
        let home = "/Users/Jane Doe/.config/blackice/agent"
        let arguments = CLI.claudeCodeArguments()
        #expect(arguments.starts(with: ["-p", "--restricted", "--safe-mode", "--tools", "Read"]))
        // The instructions the daemon writes into the event's directory, its working directory.
        #expect(arguments.suffix(3) == ["--system-prompt-file", "instructions.md", CLI.claudeCodePrompt])
        #expect(AgentInstructions.claudeCode.files.map(\.path) == ["instructions.md"])
        let program = CLI.agentHook(.claudeCode, executable: "/Users/Jane Doe/.local/bin/claude", agentHome: home, identity: Self.claude)
        let text = "mode = \"ask\"\n" + CLI.agentAddition("claude-code", identity: Self.claude, hosts: ["api.anthropic.com"], hook: program)
        let config = try BlackiceConfig(data: Data(text.utf8))
        #expect(config.hooks.first?.program == program && program.eventOnStdin == false)
        #expect(CLI.agentRunning(config.hooks[0])?.name == "claude-code")
        #expect(AgentProfile.known.map(\.name) == ["fx", "claude-code"])

        // The eval runs the same arguments, in the same order.
        let adapter = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("integrations/eval/agents/claude-code.sh"),
                                 encoding: .utf8)
        var rest = Substring(adapter)
        for argument in arguments.dropLast(2) {
            // The model can be changed for a run (MODEL=haiku); the hook's is the default.
            let word = argument == "sonnet" ? "\"${MODEL:-sonnet}\"" : "\"" + argument + "\""
            let range = try #require(rest.range(of: word), "\(argument) is not in the eval's arguments")
            rest = rest[range.upperBound...]
        }
        #expect(adapter.contains("\"\(CLI.claudeCodePrompt)\"") && adapter.contains("agent_stdin=none"))
    }

    @Test func connectsFxEndToEnd() throws {
        let (home, config) = try setUp("""
            mode = "accept-all"     # accept-all, ask or block-all
            timeout_seconds = 10    # in ask mode, no answer in time means deny

            [[allow]]
            app = "com.apple.curl"
            hosts = ["pypi.org"]
            """)
        defer { removeTree(home) }
        // A home made by hand earlier, readable by others (3 November 2026, on the test Mac).
        let handMade = home.appendingPathComponent(".config/blackice/agent/.fx")
        try FileManager.default.createDirectory(at: handMade, withIntermediateDirectories: true)
        for folder in [".config/blackice/agent", ".config/blackice/agent/.fx"] {
            chmod(home.appendingPathComponent(folder).path, 0o755)
        }
        let mac = FakeAgentMac(signedIn: false, answer: Self.approve)
        let system = Loading()
        let result = connect(home, config: config, mac: mac, system: system, answers: ["y"])
        #expect(result.status == 0, "\(result.stderr)")

        // Its home: a sign-in with its own HOME and no keychain, and the rules. No skill: the
        // daemon writes it into each event's directory, fx's workspace.
        let agent = home.path + "/.config/blackice/agent"
        #expect(!FileManager.default.fileExists(atPath: agent + "/.fx/skills"))
        #expect(mac.logins == [["HOME": agent, "FX_DISABLE_KEYCHAIN": "1"]])
        let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: agent + "/.fx/settings.json"))) as? [String: Any])
        #expect(settings["permission_mode"] as? String == "ask")
        let bash = try #require((settings["permission"] as? [String: Any])?["bash"] as? [String: String])
        #expect(bash == ["*": "deny"])
        for folder in [agent, agent + "/.fx"] { #expect(try permissions(URL(fileURLWithPath: folder)) == 0o700) }
        #expect(!FileManager.default.fileExists(atPath: agent + "/test"))
        #expect(result.stdout.contains("  ✓ Its home is ~/.config/blackice/agent; its instructions come with blackice"))

        // The test ran the same hook the file now holds: fx itself, with its signature, in its home.
        #expect(mac.hookRuns.map(\.program) == [Self.program(home)])
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.mode == .ask && loaded.timeoutSeconds == 60)
        #expect(written.contains("mode = \"ask\"".padding(toLength: 24, withPad: " ", startingAt: 0) + "# accept-all, ask or block-all\n"))
        for host in AgentProfile.fx.hosts { #expect(loaded.allowRule(for: Self.fx, host: host) != nil) }
        #expect(loaded.allowRule(for: SigningIdentity(signingID: "com.apple.curl", teamID: nil), host: "pypi.org") != nil)
        #expect(loaded.hooks.map(\.program) == [Self.program(home)] && loaded.hooks[0].run == nil)
        #expect(written.hasSuffix("""
            [[hook]]
            on = "connection"
            program = "/opt/fake/fx"
            app = "com.vercel.fx"
            team = "JW6Y669B67"
            args = ["ask", "--no-save", "--no-color", "\(AgentProfile.prompt)"]
            env = ["FX_DISABLE_KEYCHAIN=1", "HOME=\(agent)"]
            instructions = "fx"

            """))
        #expect(system.texts == [written] && system.agentInstalls == 1)

        #expect(result.stdout.contains("1 · Find fx"))
        #expect(result.stdout.contains("  ✓ /opt/fake/fx is com.vercel.fx, team JW6Y669B67"))
        #expect(result.stdout.contains("  ✓ fx approved it in 14 s"))
        #expect(result.stdout.contains("  ✓ A rule lets fx reach its model in every mode:"))
        #expect(result.stdout.contains("    ai-gateway.vercel.sh, vercel.com and api.vercel.com"))
        #expect(result.stdout.contains("  ✓ timeout_seconds is now 60, so fx has time to answer"))
        #expect(result.stdout.last == "✓ fx answers what no rule covers. See what waits with: blackice pending")

        // Again: nothing to add, no sign-in, no question; it loads the same file.
        let again = connect(home, config: config, mac: mac, system: system)
        #expect(again.status == 0, "\(again.stderr)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written)
        #expect(mac.logins.count == 1 && system.texts == [written, written])
        #expect(again.stdout.contains("  fx could already reach its model's hosts."))
        #expect(again.stdout.contains { $0.hasPrefix("  A hook already starts fx (line ") })
    }

    @Test func noAnswerLeavesTheFileAlone() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let system = Loading()
        let silent = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: nil),
                             system: system)
        #expect(silent.status == ExitCode.software)
        #expect(silent.stderr.first == "  fx exited with status 0 and gave no answer, so blackice.toml was left as it was.")
        #expect(silent.stderr.contains("    fx: done"))
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text && system.texts.isEmpty)

        // A Vercel team with no card on file (3 November 2026): say what to do about it.
        let unpaid = FakeAgentMac(signedIn: true, answer: nil)
        unpaid.hookStderr = "fx ask: API access denied · HTTP 403 · customer_verification_required: AI Gateway requires a valid credit card"
        let refused = connect(home, config: config, mac: unpaid, system: system)
        #expect(refused.status == ExitCode.software)
        #expect(refused.stderr.contains("  Vercel's AI Gateway needs a card on file for the team fx signed in with. Add one"))
        #expect(refused.stderr.last == "  To retry: blackice agent connect fx --config ~/.config/blackice/blackice.toml")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text && system.texts.isEmpty)

        // A team with no credits left (4 November 2026): fx exits with status 1 and prints nothing.
        let broke = FakeAgentMac(signedIn: true, answer: nil)
        broke.hookOutcome = .exited(status: 1)
        broke.hookStderr = "fx ask: API request failed · HTTP 502 · insufficient_funds: A positive credit balance is required"
        let unfunded = connect(home, config: config, mac: broke, system: system)
        #expect(unfunded.status == ExitCode.software)
        #expect(unfunded.stderr.first == "  fx exited with status 1 and gave no answer, so blackice.toml was left as it was.")
        #expect(unfunded.stderr.suffix(4) == [
            "  Vercel's AI Gateway has no credits left for the team fx signed in with. Add",
            "  credits on that team's AI Gateway page in the Vercel dashboard",
            "  (https://vercel.com/dashboard, then AI Gateway), then run this again.",
            "  To retry: blackice agent connect fx --config ~/.config/blackice/blackice.toml",
        ])
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text && system.texts.isEmpty)

        // The old way of answering, or anything else that is not an answer line, is no answer.
        let commandLine = connect(home, config: config, mac: FakeAgentMac(signedIn: true,
                                                                         answer: { _ in "blackice approve --app x --for 1h" }),
                                  system: system)
        #expect(commandLine.status == ExitCode.software)
        #expect(commandLine.stderr.first == "  fx ended with a line that is not an answer (\"blackice approve --app x…\"), " +
                "so blackice.toml was left as it was.")
        let failing = FakeAgentMac(signedIn: true, answer: Self.approve)
        failing.hookOutcome = .exited(status: 1)
        #expect(connect(home, config: config, mac: failing, system: system).stderr.first
                == "  fx exited with status 1 and gave no answer, so blackice.toml was left as it was.")
        let replaced = FakeAgentMac(signedIn: true, answer: Self.approve)
        replaced.hookOutcome = .refused(found: "invalid_signature")
        #expect(connect(home, config: config, mac: replaced, system: system).stderr.first
                == "  fx is signed as invalid_signature and the hook would not start it, so blackice.toml was left as it was.")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text && system.texts.isEmpty)

        // Saying no to ask mode loads it as it is.
        let declined = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                               system: system, answers: ["n"])
        #expect(declined.status == 0)
        #expect(try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))).mode == .acceptAll)
        #expect(declined.stdout.last == "✓ fx is ready. When you want it answering: blackice mode ask")

        // The end of input at that question is no, the default: it loads as it is too.
        let ended = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                            system: system)
        #expect(ended.status == 0 && system.texts.count == 2)
        #expect(ended.stdout.last == "✓ fx is ready. When you want it answering: blackice mode ask")
    }

    @Test func offersToInstallFx() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let installer = "curl -fsSL https://fx.sh/setup.sh | bash"

        // No: nothing runs and nothing changes.
        let declining = FakeAgentMac(signedIn: false, answer: Self.approve)
        declining.installed = false
        let declined = connect(home, config: config, mac: declining, system: Loading(), answers: ["n"])
        #expect(declined.status == ExitCode.unavailable && declining.installs.isEmpty)
        #expect(declined.stdout.contains("  fx is not installed. Its installer, from https://github.com/vercel-labs/fx:"))
        #expect(declined.stdout.contains("    " + installer))
        #expect(declined.stderr == ["  fx is not installed. Install it (https://github.com/vercel-labs/fx),",
                                    "  then: blackice agent connect fx --config ~/.config/blackice/blackice.toml"])
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)

        // An installer that leaves no fx behind.
        let failing = FakeAgentMac(signedIn: false, answer: Self.approve)
        let broken = AgentMachine(findExecutable: { _ in nil }, runAttached: failing.machine.runAttached,
                                  runCaptured: failing.machine.runCaptured, runHook: failing.machine.runHook)
        let out = Recorder<String>(), err = Recorder<String>()
        var script = ["y"]
        let status = CLI.run(["agent", "connect", "fx", "--config", config], stdout: { out.append($0) }, stderr: { err.append($0) },
                             system: Loading(), interaction: Interaction(ask: { _ in script.isEmpty ? nil : script.removeFirst() },
                                                                         createFile: CLI.createFile, identify: { _ in nil },
                                                                         fileExists: { _ in true }, home: home.path, version: nil),
                             agents: broken)
        #expect(status == ExitCode.unavailable && failing.installs == [["-o", "pipefail", "-c", installer]])
        #expect(err.items.first == "  fx's installer exited with status 0, and fx is still not")

        // Enter installs it, and the rest goes on: sign-in, test, rule and hook.
        let mac = FakeAgentMac(signedIn: false, answer: Self.approve)
        mac.installed = false
        let system = Loading()
        let result = connect(home, config: config, mac: mac, system: system, answers: ["", "y"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(mac.installs == [["-o", "pipefail", "-c", installer]] && mac.logins.count == 1)
        #expect(result.stdout.contains("  ✓ /opt/fake/fx is com.vercel.fx, team JW6Y669B67"))
        #expect(try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))).mode == .ask)
    }

    @Test func startPicksFxAndSetsEverythingUp() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let config = home.path + "/.config/blackice/blackice.toml"
        let mac = FakeAgentMac(signedIn: false, answer: Self.approve)
        mac.installed = false
        let system = Loading()
        var picks: [[Int]] = [[1], [0], []]   // ask, fx answers, no apps
        var typed = [""]                      // Enter installs fx
        let interaction = Interaction(
            ask: { _ in typed.isEmpty ? nil : typed.removeFirst() }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/fx" ? Self.fx : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil, choose: { _ in picks.isEmpty ? nil : picks.removeFirst() })
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["start", "--config", config], stdout: { out.append($0) }, stderr: { err.append($0) },
                             system: system, interaction: interaction, agents: mac.machine)
        #expect(status == 0, "\(err.items)")

        // First in accept-all with no Next list, then the file as written: ask mode, fx's rule and hook.
        #expect(system.texts.count == 2 && system.nexts == [false, true])
        #expect(try BlackiceConfig(data: Data(system.texts[0].utf8)).mode == .acceptAll)
        let final = try BlackiceConfig(data: Data(system.texts[1].utf8))
        #expect(final.mode == .ask && final.hooks.count == 1 && final.allowRule(for: Self.fx, host: "ai-gateway.vercel.sh") != nil)
        #expect(try String(contentsOfFile: config, encoding: .utf8) == system.texts[1])
        #expect(mac.installs.count == 1 && mac.logins.count == 1 && system.agentInstalls == 1 && system.modes.isEmpty)
        for heading in ["1 · Pick a mode", "4 · Find fx", "5 · Give fx a home of its own", "6 · Try it on a sample connection",
                        "7 · Add fx to ~/.config/blackice/blackice.toml", "8 · Turn it on"] {
            #expect(out.items.contains(heading), "\(heading)")
        }
        #expect(out.items.contains("  It stays in accept-all while fx is set up, then switches to ask."))
        #expect(!out.items.contains { $0.hasPrefix("Connecting fx") || $0.contains("Switch to ask mode now?") })
    }

    @Test func aFailedSignInIsOfferedAgain() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let retried = FakeAgentMac(signedIn: false, answer: Self.approve)
        retried.loginFailures = 1
        let result = connect(home, config: config, mac: retried, system: Loading(), answers: ["", "n"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(retried.logins.count == 2 && result.stdout.contains("  ✓ fx is signed in"))

        let before = try String(contentsOfFile: config, encoding: .utf8)
        let given = FakeAgentMac(signedIn: false, answer: Self.approve)
        given.loginFailures = 1
        let quit = connect(home, config: config, mac: given, system: Loading(), answers: ["n"])
        #expect(quit.status == ExitCode.software && given.logins.count == 1)
        #expect(quit.stderr == ["  fx is still not signed in, so nothing else changed. To retry: blackice agent connect fx" +
                                " --config ~/.config/blackice/blackice.toml"])
        #expect(try String(contentsOfFile: config, encoding: .utf8) == before && before != text)
    }

    @Test func connectingWhileAskingSwitchesToAcceptAllFirst() throws {
        let (home, config) = try setUp("mode = \"ask\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let system = Loading()
        system.running = .ask
        let result = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                             system: system)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(system.modes == [.acceptAll])
        #expect(result.stdout.contains("blackice is in ask mode, so fx's installer, its sign-in and the test"))
        #expect(try BlackiceConfig(data: Data(system.texts.last!.utf8)).mode == .ask)
    }

    /// A setup that switched to accept-all and stops before it loads the file switches back,
    /// whatever stopped it, instead of leaving every connection let through.
    @Test func aSetupThatStopsLeavesAcceptAll() throws {
        let (home, config) = try setUp("mode = \"ask\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let back = "The setup did not finish, so blackice leaves accept-all for ask mode."

        // fx gives no answer in the test.
        let silent = Loading()
        silent.running = .ask
        let unanswered = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: nil),
                                 system: silent)
        #expect(unanswered.status == ExitCode.software)
        #expect(silent.modes == [.acceptAll, .ask] && silent.running == .ask && silent.texts.isEmpty)
        #expect(unanswered.stdout.contains("before that, it switches back to ask mode.") && unanswered.stdout.contains(back))

        // The last step's Touch ID is cancelled: back to block-all, the mode before.
        let cancelled = Loading()
        cancelled.running = .blockAll
        cancelled.startStatuses = [ExitCode.noPermission]
        let lastStep = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                               system: cancelled)
        #expect(lastStep.status == ExitCode.noPermission)
        #expect(cancelled.modes == [.acceptAll, .blockAll] && cancelled.running == .blockAll && cancelled.texts.count == 1)

        // The way back is cancelled too: say how to leave accept-all.
        let stuck = Loading()
        stuck.running = .ask
        stuck.modeStatuses = [0, ExitCode.noPermission]
        let left = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: nil), system: stuck)
        #expect(left.status == ExitCode.software && stuck.running == .acceptAll)
        #expect(left.stderr.last == "blackice is still in accept-all mode: every connection goes through. To leave it: blackice mode ask")

        // The switch itself was cancelled: there is nothing to undo.
        let declined = Loading()
        declined.running = .ask
        declined.modeStatuses = [ExitCode.noPermission]
        let refused = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                              system: declined)
        #expect(refused.status == ExitCode.noPermission && declined.modes == [.acceptAll] && declined.running == .ask)
        #expect(!refused.stdout.contains(back))
    }

    /// Control-C while fx signs in, while it decides the sample event, or at a question stops the
    /// setup there, and it goes back to the mode it put off, as any other stop does.
    @Test func controlCStopsTheSetupAndGoesBack() throws {
        let (home, config) = try setUp("mode = \"ask\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let before = try String(contentsOfFile: config, encoding: .utf8)
        let back = "The setup did not finish, so blackice leaves accept-all for ask mode."
        func asking() -> Loading { let system = Loading(); system.running = .ask; return system }

        // fx gets Control-C from the terminal and dies of it; blackice stays to go back.
        let signingIn = FakeAgentMac(signedIn: false, answer: Self.approve)
        signingIn.controlC = .signIn
        let firstSystem = asking()
        let signIn = connect(home, config: config, mac: signingIn, system: firstSystem)
        #expect(signIn.status == ExitCode.interrupted)
        #expect(signIn.stderr == ["  Interrupted, so the setup stops here."])
        #expect(firstSystem.modes == [.acceptAll, .ask] && firstSystem.running == .ask && firstSystem.texts.isEmpty)
        #expect(signIn.stdout.contains(back) && signingIn.hookRuns.isEmpty)
        #expect(signingIn.catches == 1 && signingIn.releases == 1)

        let testing = FakeAgentMac(signedIn: true, answer: Self.approve)
        testing.controlC = .test
        let secondSystem = asking()
        let test = connect(home, config: config, mac: testing, system: secondSystem)
        #expect(test.status == ExitCode.interrupted && test.stderr == ["  Interrupted, so the setup stops here."])
        #expect(secondSystem.modes == [.acceptAll, .ask] && secondSystem.texts.isEmpty)
        #expect(try String(contentsOfFile: config, encoding: .utf8) == before)

        // At "Install fx now?": nothing is installed.
        let missing = FakeAgentMac(signedIn: false, answer: Self.approve)
        missing.installed = false
        let thirdSystem = asking()
        let question = connect(home, config: config, mac: missing, system: thirdSystem, answers: [Self.controlC])
        #expect(question.status == ExitCode.interrupted && missing.installs.isEmpty)
        #expect(thirdSystem.modes == [.acceptAll, .ask] && question.stdout.contains(back))

        // At the last question, once fx's rule and hook are saved: the file is not loaded.
        let (blockHome, blockConfig) = try setUp("mode = \"block-all\"\ntimeout_seconds = 60\n")
        defer { removeTree(blockHome) }
        let blocking = Loading()
        blocking.running = .blockAll
        let last = connect(blockHome, config: blockConfig, mac: FakeAgentMac(signedIn: true,
                                                                            answer: Self.approve),
                           system: blocking, answers: [Self.controlC])
        #expect(last.status == ExitCode.interrupted && blocking.texts.isEmpty && blocking.agentInstalls == 0)
        #expect(blocking.modes == [.acceptAll, .blockAll] && blocking.running == .blockAll)
        #expect(try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: blockConfig))).hooks.count == 1)
    }

    /// The first start picked ask mode with fx answering, and fx could not be set up. Nothing was
    /// filtered before that start, so it stays in accept-all, and says so plainly.
    @Test func aFirstStartWhoseAgentFailsStaysInAcceptAll() throws {
        func firstStart(_ answers: [String]) throws -> (status: Int32, system: Loading, stdout: [String], stderr: [String],
                                                       written: BlackiceConfig) {
            let home = try makePrivateDirectory()
            defer { removeTree(home) }
            let config = home.path + "/.config/blackice/blackice.toml"
            let mac = FakeAgentMac(signedIn: false, answer: Self.approve)
            mac.installed = false
            let system = Loading()
            var picks: [[Int]] = [[1], [0], []]   // ask, fx answers, no apps
            var typed = answers
            let interaction = Interaction(
                ask: { _ in
                    guard !typed.isEmpty else { return nil }
                    let answer = typed.removeFirst()
                    if answer == Self.controlC { mac.interrupted = true; return nil }
                    return answer
                }, createFile: CLI.createFile,
                identify: { _ in nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
                home: home.path, version: nil, choose: { _ in picks.isEmpty ? nil : picks.removeFirst() })
            let out = Recorder<String>(), err = Recorder<String>()
            let status = CLI.run(["start", "--config", config], stdout: { out.append($0) }, stderr: { err.append($0) },
                                 system: system, interaction: interaction, agents: mac.machine)
            return (status, system, out.items, err.items, try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))))
        }
        let advice = ["To finish it: blackice agent connect fx --config ~/.config/blackice/blackice.toml",
                      "To filter without an agent: blackice mode ask, or blackice mode block-all"]

        let declined = try firstStart(["n"])   // do not install fx
        #expect(declined.status == ExitCode.unavailable)
        #expect(declined.system.texts.count == 1 && declined.system.modes.isEmpty && declined.system.running == .acceptAll)
        #expect(Array(declined.stderr.suffix(5)) == [
            "", "blackice is on in accept-all mode and filters nothing: every connection goes through.",
            "The fx setup failed at step 4 (Find fx), for the reason above.",
        ] + advice)
        #expect(!declined.stdout.contains { $0.hasPrefix("The setup did not finish") })
        // The file keeps the mode picked, for agent connect to load once fx is set up.
        #expect(declined.written.mode == .ask)

        let interrupted = try firstStart([Self.controlC])
        #expect(interrupted.status == ExitCode.interrupted && interrupted.system.modes.isEmpty)
        #expect(Array(interrupted.stderr.suffix(6)) == [
            "  Interrupted, so the setup stops here.",
            "", "blackice is on in accept-all mode and filters nothing: every connection goes through.",
            "The fx setup was interrupted at step 4 (Find fx).",
        ] + advice)
    }

    /// An edit to blackice.toml while fx is set up is kept: the file is read again before fx's rule
    /// and hook go in. An edit while the file is being saved makes the save stop instead.
    @Test func editsMadeDuringTheSetupAreKept() throws {
        let (home, config) = try setUp("mode = \"accept-all\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let rule = "\n[[allow]]\napp = \"com.apple.curl\"\nhosts = [\"pypi.org\"]\n"
        let editing = FakeAgentMac(signedIn: true, answer: Self.approve)
        editing.duringTest = {
            let handle = FileHandle(forWritingAtPath: config)
            handle?.seekToEndOfFile()
            handle?.write(Data(rule.utf8))
            try? handle?.close()
        }
        let system = Loading()
        let merged = connect(home, config: config, mac: editing, system: system, answers: ["n"])
        #expect(merged.status == 0, "\(merged.stderr)")
        #expect(merged.stdout.contains("  ~/.config/blackice/blackice.toml changed while fx was set up; the additions go on top of that."))
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(text: written)
        #expect(loaded.allowRule(for: SigningIdentity(signingID: "com.apple.curl", teamID: nil), host: "pypi.org") != nil)
        #expect(loaded.allowRule(for: Self.fx, host: "vercel.com") != nil && loaded.hooks.count == 1)
        #expect(system.texts == [written])

        // Another writer between the first save and the switch to ask mode: nothing is overwritten.
        let (otherHome, otherConfig) = try setUp("mode = \"accept-all\"\ntimeout_seconds = 60\n")
        defer { removeTree(otherHome) }
        let edited = "mode = \"block-all\"\ntimeout_seconds = 60\n"
        var script = ["y"]
        let interaction = Interaction(
            ask: { prompt in
                if prompt.contains("Switch to ask mode") { try? Data(edited.utf8).write(to: URL(fileURLWithPath: otherConfig)) }
                return script.isEmpty ? nil : script.removeFirst()
            }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/fx" ? Self.fx : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: otherHome.path, version: nil)
        let err = Recorder<String>()
        let refusing = Loading()
        let status = CLI.run(["agent", "connect", "fx", "--config", otherConfig], stdout: { _ in }, stderr: { err.append($0) },
                             system: refusing, interaction: interaction,
                             agents: FakeAgentMac(signedIn: true, answer: Self.approve).machine)
        #expect(status == ExitCode.tempFail)
        #expect(err.items.last == "  Something else changed ~/.config/blackice/blackice.toml meanwhile, so blackice agent connect left it as it is. Run it again.")
        #expect(try String(contentsOfFile: otherConfig, encoding: .utf8) == edited && refusing.texts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: CLI.temporaryPath(for: otherConfig)))
    }

    /// `--config blackice.toml` has no folder: the temporary file goes in the current one.
    @Test func aBareFileNameKeepsTheTemporaryFileBesideIt() {
        let pid = getpid()
        #expect(CLI.temporaryPath(for: "blackice.toml") == ".blackice.toml.\(pid).tmp")
        #expect(CLI.temporaryPath(for: "conf/blackice.toml") == "conf/.blackice.toml.\(pid).tmp")
        #expect(CLI.temporaryPath(for: "/Users/a/blackice.toml") == "/Users/a/.blackice.toml.\(pid).tmp")
        #expect(CLI.temporaryPath(for: "/blackice.toml") == "/.blackice.toml.\(pid).tmp")
    }

    @Test func aSymlinkedHomeIsRefused() throws {
        let (home, config) = try setUp("mode = \"accept-all\"\n")
        defer { removeTree(home) }
        let elsewhere = try makePrivateDirectory()
        defer { removeTree(elsewhere) }
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.config/blackice/agent", withDestinationPath: elsewhere.path)
        let result = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                             system: Loading())
        #expect(result.status == ExitCode.cannotCreate)
        #expect(result.stderr.first?.contains("is not a directory (a symlink is not accepted either)") == true)
    }

    @Test func refusals() throws {
        let (home, config) = try setUp("mode = \"accept-all\"\n")
        defer { removeTree(home) }
        let mac = FakeAgentMac(signedIn: true, answer: Self.approve)
        let other = connect(home, config: config, mac: mac, system: Loading(), arguments: ["agent", "connect", "claude"])
        #expect(other.status == ExitCode.usage
            && other.stderr.first?.hasPrefix("blackice agent connect knows fx and claude-code so far") == true)

        let missing = connect(home, config: home.path + "/none.toml", mac: mac, system: Loading())
        #expect(missing.status == ExitCode.unreadable)
        #expect(missing.stderr.last == "Set blackice up first, then connect fx: blackice start --config ~/none.toml")

        var noFx = mac.machine
        noFx = AgentMachine(findExecutable: { _ in nil }, runAttached: noFx.runAttached, runCaptured: noFx.runCaptured,
                            runHook: noFx.runHook)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["agent", "connect", "fx", "--config", config], stdout: { out.append($0) }, stderr: { err.append($0) },
                             system: Loading(), interaction: Interaction(ask: { _ in nil }, createFile: CLI.createFile,
                                                                         identify: { _ in nil }, fileExists: { _ in true },
                                                                         home: home.path, version: nil), agents: noFx)
        #expect(status == ExitCode.unavailable && err.items.first?.hasPrefix("  fx is not installed.") == true)

        let quiet = Recorder<String>()
        #expect(CLI.run(["agent", "connect", "fx"], stdout: { _ in }, stderr: { quiet.append($0) }) == ExitCode.usage)
        #expect(quiet.items == ["blackice agent connect asks questions and signs fx in, so it needs a terminal."])
        #expect(throws: (any Error).self) { try CLI.parse(["agent", "connect"]) }
        #expect(try CLI.parse(["agent", "connect", "fx", "--config", "/x.toml"]) == .connectAgent(name: "fx", configPath: "/x.toml"))
    }

    /// A hook from 0.3, a `run` line that no signature check covers, is replaced with fx's program
    /// hook; the rest of the file stays as it was.
    @Test func aRunHookFromBeforeIsReplaced() throws {
        let (home, config) = try setUp("""
            mode = "ask"
            timeout_seconds = 60

            # fx answers the connections that wait in ask mode (added by blackice agent connect fx).
            [[allow]]
            app = "com.vercel.fx"
            team = "JW6Y669B67"
            hosts = ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"]

            [[hook]]
            on = "connection"
            run = 'FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="/x" "/opt/fake/fx" ask --no-save --no-color "\(AgentProfile.prompt)"'
            # a note about the next rule

            [[allow]]
            app = "com.apple.curl"
            hosts = ["pypi.org"]
            """)
        defer { removeTree(home) }
        let system = Loading()
        let result = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                             system: system)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("  ✓ The hook on line 10 now starts fx itself, once its signature checks out"))
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.hooks.map(\.program) == [Self.program(home)] && loaded.hooks[0].line == 10)
        #expect(loaded.allow.count == 2 && !written.contains("run = "))
        #expect(written.contains("env = [\"FX_DISABLE_KEYCHAIN=1\", \"HOME=\(Self.agent(home))\"]\ninstructions = \"fx\"\n" +
                                 "# a note about the next rule\n\n[[allow]]"))
    }

    /// The test runs with the owner's notes, as the daemon would, and the [agent] table stays as it was,
    /// a line of the notes that looks like a table header included.
    @Test func theOwnersNotesGoWithTheTest() throws {
        let notes = "I build with the tools in /opt/tools.\n[Not a table] Deny analytics hosts."
        let agentTable = "[agent]\nnotes = \"\"\"\n\(notes)\"\"\"\n"
        let (home, config) = try setUp("mode = \"ask\"\n\n[[hook]]\non = \"connection\"\nrun = 'true'\n\n" + agentTable)
        defer { removeTree(home) }
        let mac = FakeAgentMac(signedIn: true, answer: Self.approve)
        let result = connect(home, config: config, mac: mac, system: Loading())
        #expect(result.status == 0, "\(result.stderr)")
        #expect(mac.notes == [notes])
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.agentNotes == notes && written.contains("\n" + agentTable))
        #expect(loaded.hooks.last?.program == Self.program(home))
    }

    @Test func pieces() throws {
        #expect(CLI.fitsConfig("/Users/Jane \"Doe\" $HOME/.local/bin/fx"))
        for bad in ["fx", "/a\nb", "/a\u{7F}b", "/a\u{85}b"] { #expect(!CLI.fitsConfig(bad)) }
        #expect(CLI.tomlString(#"/a "b" \c"#) == #""/a \"b\" \\c""#)
        #expect(CLI.replacingTable(at: 2, in: "a = 1\n[[hook]]\nx = 1\n\n# c\n[[allow]]\n", with: ["[[hook]]", "y = 2"])
                == "a = 1\n[[hook]]\ny = 2\n\n# c\n[[allow]]\n")
        #expect(CLI.replacingTable(at: 2, in: "a = 1\n[[hook]]\nx = [\n  1,\n]\n", with: ["Z"]) == "a = 1\nZ\n")

        let merged = try #require(JSONSerialization.jsonObject(with: CLI.fxSettings(Data(#"{"model":"m","permission_mode":"auto"}"#.utf8))) as? [String: Any])
        #expect(merged["model"] as? String == "m" && merged["permission_mode"] as? String == "ask")
        #expect(throws: (any Error).self) { try CLI.fxSettings(Data("[1]".utf8)) }
        #expect((try? CLI.fxSettings(nil)) != nil && (try? CLI.fxSettings(Data("\n".utf8))) != nil)

        #expect(!CLI.fxSignedIn("[status] auth=missing\n") && !CLI.fxSignedIn("nothing"))
        #expect(CLI.fxSignedIn("[status] model=x\n[status] auth=vercel"))

        func ran(_ outcome: HookResult.Outcome, _ stdout: String) -> HookResult {
            HookResult(hookLine: 0, outcome: outcome, stderr: "", stderrTruncated: false, duration: 1, stdout: Data(stdout.utf8))
        }
        #expect(CLI.testAnswer(ran(.exited(status: 0), "deny\n"), seconds: 120) == .answered(.deny))
        #expect(CLI.testAnswer(ran(.exited(status: 0), "approve 10m"), seconds: 120) == .answered(.approve(seconds: 600)))
        #expect(CLI.testAnswer(ran(.exited(status: 0), ""), seconds: 120) == .none("exited with status 0 and gave no answer"))
        #expect(CLI.testAnswer(ran(.timedOut(signal: 15), "deny"), seconds: 120) == .none("gave no answer in 120 s"))
        #expect(CLI.testAnswer(ran(.dropped(.queueFull), ""), seconds: 120) == .none("did not run (queue_full)"))

        #expect(CLI.settingRootKey("# c\nmode = \"block-all\"\n[[allow]]\nmode = 1\n", "mode", to: "\"ask\"")
            == "# c\nmode = \"ask\"\n[[allow]]\nmode = 1\n")
        #expect(CLI.settingRootKey("# c\n\n[[allow]]\n", "timeout_seconds", to: "60") == "# c\ntimeout_seconds = 60\n\n[[allow]]\n")
        #expect(CLI.listed(["a"]) == "a" && CLI.listed(["a", "b", "c"]) == "a, b and c")
        #expect(CLI.agentAddition("fx", identity: Self.fx, hosts: [], hook: nil).isEmpty)

        let event = try CLI.sampleAgentEvent()
        try event.validate(now: Date(), maximumWait: TimeInterval(CLI.agentTestSeconds))
        // The hook reads back from blackice.toml as it was written, quotes and backslashes included.
        let program = CLI.agentHook(.fx, executable: "/Users/Jane \"Doe\"/.local/bin/fx",
                                    agentHome: "/Users/Jane \"Doe\"/back\\slash/.config/blackice/agent", identity: Self.fx)
        let config = try BlackiceConfig(data: Data(("mode = \"ask\"\n" + CLI.agentAddition("fx", identity: Self.fx, hosts: ["vercel.com"],
                                                                                          hook: program)).utf8))
        #expect(config.hooks.first?.program == program && config.allowRule(for: Self.fx, host: "vercel.com") != nil)
        #expect(program.environment == ["HOME": "/Users/Jane \"Doe\"/back\\slash/.config/blackice/agent", "FX_DISABLE_KEYCHAIN": "1"])
    }
}
