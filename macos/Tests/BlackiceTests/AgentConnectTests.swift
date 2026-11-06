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
    /// The fx executables on PATH, first found first, while fx is installed.
    var found = ["/opt/fake/fx"]
    /// The environments of installs into a folder of blackice's own, whether one is there, and
    /// whether such an install leaves one there.
    var privateInstalls: [[String: String]] = []
    var privateCopy = false
    var privateInstallWorks = true
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
            findExecutables: { name, alsoIn in
                guard name == "fx" else { return [] }
                return (self.installed ? self.found : []) + (self.privateCopy ? alsoIn.map { $0 + "/fx" } : [])
            },
            runAttached: { path, arguments, environment in
                if arguments == ["login", "vercel"] {
                    self.logins.append(environment)
                    if self.controlC == .signIn { self.interrupted = true; return 128 + SIGINT }
                    if self.loginFailures > 0 { self.loginFailures -= 1; return 1 }
                    self.signedIn = true
                }
                if path == "/bin/bash" {
                    self.installs.append(arguments)
                    if environment["FX_INSTALL_DIR"] != nil {
                        self.privateInstalls.append(environment)
                        self.privateCopy = self.privateInstallWorks
                    } else {
                        self.installed = arguments.last?.contains("fx.sh") == true
                    }
                }
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
            findExecutables: { name, _ in name == "claude" ? ["/opt/fake/claude"] : [] },
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

/// A Mac with Codex at /opt/fake/codex: `login status` says whether `login` ran, and the hook
/// "decides" by printing `printed`.
private final class FakeCodexMac: @unchecked Sendable {
    var signedIn: Bool
    var printed: String
    var status: Int32 = 0
    var installed = true
    var logins: [[String: String]] = []
    var hookRuns: [Hook] = []

    init(signedIn: Bool, printed: String) {
        self.signedIn = signedIn
        self.printed = printed
    }

    var machine: AgentMachine {
        AgentMachine(
            findExecutables: { name, _ in name == "codex" && self.installed ? ["/opt/fake/codex"] : [] },
            runAttached: { _, arguments, environment in
                if arguments == ["login"] { self.logins.append(environment); self.signedIn = true }
                return 0
            },
            runCaptured: { _, arguments, _ in
                arguments == ["login", "status"] ? (self.signedIn ? 0 : 1, self.signedIn ? "Logged in using ChatGPT\n" : "Not logged in\n")
                    : (0, "")
            },
            runHook: { hook, _, _, _, _ in
                self.hookRuns.append(hook)
                return HookResult(hookLine: 0, outcome: .exited(status: self.status), stderr: self.status == 0 ? "" :
                                    "ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header",
                                  stderrTruncated: false, duration: 5, stdout: Data(self.printed.utf8))
            })
    }
}

/// A Mac with opencode at /opt/fake/opencode, found only in ~/.opencode/bin, where its installer
/// puts it: `auth list` lists a stored sign-in for each provider `auth login` ran for, and a key
/// for Z.AI in the shell's environment, which does not count; the hook "decides" by printing `printed`.
private final class FakeOpenCodeMac: @unchecked Sendable {
    var providers: [String] = []
    var printed: String
    var status: Int32 = 0
    var logins: [[String]] = []
    var environments: [[String: String]] = []
    var hookRuns: [Hook] = []

    init(printed: String) {
        self.printed = printed
    }

    var machine: AgentMachine {
        AgentMachine(
            findExecutables: { name, alsoIn in
                name == "opencode" && alsoIn.contains { $0.hasSuffix("/.opencode/bin") } ? ["/opt/fake/opencode"] : []
            },
            runAttached: { _, arguments, environment in
                if arguments.starts(with: ["auth", "login", "--standalone"]), let id = arguments.last {
                    self.logins.append(arguments)
                    self.environments.append(environment)
                    self.providers.append(id)
                }
                return 0
            },
            runCaptured: { _, arguments, _ in
                guard arguments == ["auth", "list", "--standalone", "--format", "json"] else { return (0, "") }
                let stored = self.providers.map { "{\"id\":\"\($0)\",\"name\":\"\($0)\",\"connections\":[{\"type\":\"api\"}]}" }
                let shell = "{\"id\":\"zai-coding-plan\",\"name\":\"Z.AI Coding Plan\",\"connections\":[{\"type\":\"env\",\"name\":\"ZHIPU_API_KEY\"}]}"
                return (0, "[" + (stored + [shell]).joined(separator: ",") + "]\n")
            },
            runHook: { hook, _, _, _, _ in
                self.hookRuns.append(hook)
                return HookResult(hookLine: 0, outcome: .exited(status: self.status),
                                  stderr: self.status == 0 ? "" : "Error: Model unavailable: zai-coding-plan/glm-5.3-flash",
                                  stderrTruncated: false, duration: 4, stdout: Data(self.printed.utf8))
            })
    }
}

/// Loads what it is given and keeps the mode saved. `startStatuses` and `modeStatuses` answer the
/// calls in turn (0 once they run out); a call that fails changes nothing, as with Touch ID cancelled.
private final class Loading: SystemControlling {
    var texts: [String] = []
    var nexts: [Bool] = []
    var asWritten: [Bool] = []
    var agentInstalls = 0
    var running: Mode?
    var modes: [Mode] = []
    var startStatuses: [Int32] = []
    var modeStatuses: [Int32] = []
    func start(configText: String, output: SystemOutput) -> Int32 {
        texts.append(configText); nexts.append(output.next); asWritten.append(output.asWritten)
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
    /// fx's release signature on /opt/fake/fx and on the copy blackice installs for itself; none
    /// on anything else, such as a development build at /opt/dev/fx.
    static func identifyFx(_ path: String) -> SigningIdentity? {
        path == "/opt/fake/fx" || path.hasSuffix("/.config/blackice/agent/bin/fx") ? fx : nil
    }
    static func program(_ home: URL, path: String = "/opt/fake/fx") -> HookProgram {
        HookProgram(path: path, arguments: ["ask", "--no-save", "--no-color", "--model", "anthropic/claude-haiku-5.5",
                                                      "--system", CLI.fxSystemPrompt, AgentProfile.prompt],
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
            identify: Self.identifyFx, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(arguments ?? ["agent", "connect", "fx", "--config", config], stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: system, interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    static let claude = SigningIdentity(signingID: "com.anthropic.claude-code", teamID: "Q6L2SF6YDW")
    static func claudeProgram(_ home: URL) -> HookProgram {
        HookProgram(path: "/opt/fake/claude", arguments: CLI.claudeCodeArguments(model: AgentProfile.claudeCode.defaultModel),
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
    /// earlier rule lacked, in place of fx's hook from 0.4.0, which named no instructions. Then fx
    /// again: Claude Code's hook stays, and `answers` names fx.
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
        #expect(result.stdout.contains("✓ Removed the copies of the instructions earlier versions put in ~/.config/blackice/agent"))
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

        #expect(result.stdout.contains("  ✓ /opt/fake/claude (com.anthropic.claude-code, team Q6L2SF6YDW)"))
        #expect(result.stdout.contains("  ✓ reads the event only: no shell, no web, no MCP servers"))
        #expect(result.stdout.contains("  ✓ approved it in 6 s"))
        #expect(result.stdout.contains("  ✓ rule: claude-code may reach platform.claude.com in every mode"))
        #expect(result.stdout.contains("  ✓ hook on line 9: was fx, now claude-code"))
        #expect(loaded.answers == nil && !written.contains("[agent]"))

        // Again: nothing changes.
        let again = connectClaude(home, config: config, mac: mac, system: system)
        #expect(again.status == 0, "\(again.stderr)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written && mac.logins.count == 1)
        #expect(again.stdout.contains("  ✓ ~/.config/blackice/blackice.toml has claude-code's rule and hook already"))

        // fx beside Claude Code: both hooks, and fx answers.
        let back = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                           system: system)
        #expect(back.status == 0, "\(back.stderr)")
        let both = try String(contentsOfFile: config, encoding: .utf8)
        let fxConfig = try BlackiceConfig(data: Data(both.utf8))
        #expect(fxConfig.hooks.map(\.program) == [Self.claudeProgram(home), Self.program(home)] && fxConfig.hooks[0].line == 9)
        #expect(fxConfig.answers == .agent(.fx) && fxConfig.activeHooks.map(\.program) == [Self.program(home)])
        #expect(both.hasSuffix("\n[agent]\nanswers = \"fx\"\n"))
        #expect(fxConfig.answering == Answering(agents: [.claudeCode, .fx], answerer: .agent(.fx)))
        #expect(back.stdout.contains("  ✓ answers = \"fx\"; claude-code stays connected: blackice mode ask --agent claude-code"))

        // Claude Code again: its hook stays as it is, and answers names it.
        let other = connectClaude(home, config: config, mac: mac, system: system)
        #expect(other.status == 0, "\(other.stderr)")
        let swapped = try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config)))
        #expect(swapped.hooks.map(\.program) == fxConfig.hooks.map(\.program) && swapped.answers == .agent(.claudeCode))
        #expect(other.stdout.contains("  ✓ answers = \"claude-code\"; fx stays connected: blackice mode ask --agent fx"))
    }

    /// Hooks that name no instructions would run whatever `answers` says: the agent's own becomes
    /// its new hook, and the other agent's goes.
    @Test func hooksWithoutInstructionsGo() throws {
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
        #expect(loaded.hooks.map(\.program) == [Self.claudeProgram(home)] && loaded.hooks[0].line == 9)
        #expect(loaded.allow.map(\.app) == ["com.apple.curl", "com.anthropic.claude-code"] && loaded.answers == nil)
        #expect(result.stdout.contains("  ✓ hook on line 12: now starts claude-code directly"))
        #expect(result.stdout.contains("  ✓ removed the hook on line 4, which ran fx"))
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
        #expect(refused.stderr.first == "  claude-code exited with status 1 and no answer, so blackice.toml was left as it was.")
        #expect(refused.stderr.contains("    Not logged in · Please run /login"))
        #expect(refused.stderr.contains("  CLAUDE_CONFIG_DIR=~/.config/blackice/agent/.claude claude auth login"))
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)
    }

    static let codex = SigningIdentity(signingID: "codex", teamID: "2DC432GLL2")
    static func codexProgram(_ home: URL, model: String = AgentProfile.codex.defaultModel) -> HookProgram {
        HookProgram(path: "/opt/fake/codex", arguments: CLI.codexArguments(model: model),
                    environment: ["CODEX_HOME": agent(home) + "/.codex"], identity: codex, eventOnStdin: false,
                    instructions: .codex)
    }

    private func connectCodex(_ home: URL, config: String, mac: FakeCodexMac, system: Loading,
                              extra: [String] = []) -> Connected {
        let interaction = Interaction(
            ask: { _ in nil }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/codex" ? Self.codex : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["agent", "connect", "codex", "--config", config] + extra, stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: system, interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    /// Codex: its own CODEX_HOME and sign-in, no settings file, a program hook with no event on
    /// stdin beside Claude Code's, `answers` naming it, and a rule for chatgpt.com and auth.openai.com.
    @Test func connectsCodexBesideClaudeCode() throws {
        let (home, config) = try setUp("""
            mode = "ask"
            timeout_seconds = 60

            [[hook]]
            on = "connection"
            program = "/opt/fake/claude"
            app = "com.anthropic.claude-code"
            team = "Q6L2SF6YDW"
            args = ["-p", "\(CLI.claudeCodePrompt)"]
            stdin = "none"
            instructions = "claude-code"
            """)
        defer { removeTree(home) }
        let mac = FakeCodexMac(signedIn: false, printed: "com.microsoft.VSCode -> update.code.visualstudio.com: its update server\napprove 12h\n")
        let system = Loading()
        let result = connectCodex(home, config: config, mac: mac, system: system)
        #expect(result.status == 0, "\(result.stderr)")

        let agent = Self.agent(home)
        #expect(mac.logins == [["CODEX_HOME": agent + "/.codex"]])
        for folder in [agent, agent + "/.codex"] { #expect(try permissions(URL(fileURLWithPath: folder)) == 0o700) }
        #expect(mac.hookRuns == [Hook(program: Self.codexProgram(home), line: 0)])
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.hooks.map { $0.program?.instructions } == [.claudeCode, .codex] && loaded.hooks[0].line == 4)
        #expect(loaded.hooks[1].program == Self.codexProgram(home) && loaded.activeHooks.map(\.program) == [Self.codexProgram(home)])
        #expect(loaded.answers == .agent(.codex) && written.hasSuffix("\n[agent]\nanswers = \"codex\"\n"))
        #expect(written.contains("program = \"/opt/fake/codex\"\napp = \"codex\"\nteam = \"2DC432GLL2\"\n"))
        #expect(written.contains("stdin = \"none\"\ninstructions = \"codex\"\n"))
        #expect(written.contains(#""-c", "permissions.blackice.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\"}""#))
        for host in AgentProfile.codex.hosts { #expect(loaded.allowRule(for: Self.codex, host: host) != nil) }
        #expect(AgentProfile.codex.hosts == ["chatgpt.com", "auth.openai.com"])

        #expect(result.stdout.contains("  ✓ /opt/fake/codex (codex, team 2DC432GLL2)"))
        #expect(result.stdout.contains("  ✓ reads the event only: no writes, no network, no MCP servers"))
        #expect(result.stdout.contains("  Testing with gpt-6-luna on a sample connection…"))
        #expect(result.stdout.contains("  ✓ approved it in 5 s"))
        #expect(result.stdout.contains("  ✓ answers = \"codex\"; claude-code stays connected: blackice mode ask --agent claude-code"))

        // No sign-in under the hook: what to do about it, and the file as it was.
        let unsigned = FakeCodexMac(signedIn: true, printed: "")
        unsigned.status = 1
        let refused = connectCodex(home, config: config, mac: unsigned, system: system, extra: ["--model", "gpt-6.1-sol"])
        #expect(refused.status == ExitCode.software)
        #expect(refused.stderr.contains("  CODEX_HOME=~/.config/blackice/agent/.codex codex login"))
        #expect(unsigned.hookRuns.first?.program == Self.codexProgram(home, model: "gpt-6.1-sol"))
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written)
    }

    @Test func codexPieces() {
        #expect(CLI.codexSignedIn("Logged in using ChatGPT\n") && CLI.codexSignedIn("Logged in using an API key - sk-…\n"))
        #expect(!CLI.codexSignedIn("Not logged in\n") && !CLI.codexSignedIn(""))
        let arguments = CLI.codexArguments(model: "gpt-6-luna")
        #expect(arguments.starts(with: ["exec", "--strict-config"]) && arguments.last == CLI.codexPrompt)
        // Never the whole-disk read-only sandbox, which would take the profile's place.
        #expect(!arguments.contains("--sandbox") && !arguments.contains("-s"))
        #expect(arguments.contains("model_instructions_file=\"instructions.md\"") && arguments.contains("project_doc_max_bytes=0"))
        #expect(arguments.count <= BlackiceConfig.maximumHookArguments)
        #expect(CLI.agentRunning(Hook(program: Self.codexProgram(URL(fileURLWithPath: "/h")), line: 1))?.name == "codex")
    }

    static let opencode = SigningIdentity(signingID: "opencode", teamID: "5NZ4Q7NXJ4")
    static func openCodeProgram(_ home: URL, model: String) -> HookProgram {
        HookProgram(path: "/opt/fake/opencode", arguments: CLI.openCodeArguments(model: model),
                    environment: CLI.openCodeEnvironment(agentHome: agent(home)), identity: opencode, eventOnStdin: false,
                    instructions: .opencode)
    }

    private func connectOpenCode(_ home: URL, config: String, mac: FakeOpenCodeMac, answers: [String],
                                 extra: [String] = []) -> Connected {
        var script = answers
        let interaction = Interaction(
            ask: { _ in script.isEmpty ? nil : script.removeFirst() }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/opencode" ? Self.opencode : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["agent", "connect", "opencode", "--config", config] + extra, stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: Loading(), interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    /// opencode: the provider picked from the list, its sign-in in a HOME of its own, a rule for that
    /// provider's hosts and no other, and a program hook with no event on stdin.
    @Test func connectsOpenCodeWithTheProviderPicked() throws {
        let (home, config) = try setUp("mode = \"accept-all\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let mac = FakeOpenCodeMac(printed: "com.microsoft.VSCode -> update.code.visualstudio.com: its update server\napprove 12h\n")
        // 9 is not on the list; 4 is the MiniMax Token Plan; then no to ask mode.
        let result = connectOpenCode(home, config: config, mac: mac, answers: ["9", "4", "n"])
        #expect(result.status == 0, "\(result.stderr)")

        let agent = Self.agent(home)
        #expect(mac.logins == [["auth", "login", "--standalone", "minimax-coding-plan"]])
        #expect(mac.environments.first?["HOME"] == agent + "/.opencode" && mac.environments.first?["XDG_CONFIG_HOME"] == ".")
        for folder in [agent, agent + "/.opencode"] { #expect(try permissions(URL(fileURLWithPath: folder)) == 0o700) }
        let program = Self.openCodeProgram(home, model: "minimax-coding-plan/MiniMax-M3.1-Flash")
        #expect(mac.hookRuns == [Hook(program: program, line: 0)])
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.hooks.map(\.program) == [program] && loaded.answers == nil)
        #expect(written.contains("hosts = [\"api.minimax.io\"]") && loaded.allowRule(for: Self.opencode, host: "api.z.ai") == nil)
        #expect(written.contains("stdin = \"none\"\ninstructions = \"opencode\"\n"))

        #expect(result.stdout.contains("  Which provider should opencode decide with?"))
        #expect(result.stdout.contains("    4  MiniMax Token Plan (minimax-coding-plan/MiniMax-M3.1-Flash)"))
        #expect(result.stdout.contains("    Type a number from 1 to \(AgentProvider.openCode.count)."))
        #expect(result.stdout.contains("  ✓ MiniMax Token Plan"))
        #expect(result.stdout.contains("  ✓ rule: opencode may reach api.minimax.io in every mode"))
        #expect(result.stdout.contains("  Testing with minimax-coding-plan/MiniMax-M3.1-Flash on a sample connection…"))
        #expect(result.stdout.contains("  ✓ reads the event only: no shell, no edits, no web, no MCP servers"))
    }

    /// `--model PROVIDER/MODEL` picks the provider without the list. A key in the shell's
    /// environment is not a sign-in, and a hook that finds none says how to sign opencode in.
    @Test func openCodeProviderFromTheModel() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let mac = FakeOpenCodeMac(printed: "")
        mac.status = 1
        let refused = connectOpenCode(home, config: config, mac: mac, answers: [], extra: ["--model", "zai-coding-plan/glm-5.3"])
        #expect(refused.status == ExitCode.software)
        #expect(!refused.stdout.contains { $0.contains("Which provider") })
        #expect(mac.logins == [["auth", "login", "--standalone", "zai-coding-plan"]])
        #expect(mac.hookRuns.first?.program == Self.openCodeProgram(home, model: "zai-coding-plan/glm-5.3"))
        #expect(refused.stderr.contains("  HOME=~/.config/blackice/agent/.opencode opencode auth login --standalone zai-coding-plan"))
        #expect(refused.stderr.contains { $0.hasPrefix("  To retry: blackice agent connect opencode --config ") && $0.hasSuffix(" --model zai-coding-plan/glm-5.3") })
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)

        for model in ["glm-5.3-flash", "gemini/flash"] {
            let wrong = connectOpenCode(home, config: config, mac: FakeOpenCodeMac(printed: ""), answers: [], extra: ["--model", model])
            #expect(wrong.status == ExitCode.usage, "\(model)")
            #expect(wrong.stderr.first == "agent connect: opencode's --model is PROVIDER/MODEL, such as openai/gpt-6-luna, with one of")
        }
        // The end of input at the list: nothing changes.
        let none = connectOpenCode(home, config: config, mac: FakeOpenCodeMac(printed: ""), answers: [])
        #expect(none.status == ExitCode.usage && none.stderr == ["  No provider chosen, so nothing changed."])
    }

    @Test func openCodePieces() throws {
        let stored = "[{\"id\":\"zai-coding-plan\",\"name\":\"Z.AI Coding Plan\",\"connections\":[{\"type\":\"api\"}]}]"
        #expect(CLI.openCodeSignedIn("A notice first\n" + stored + "\n", provider: "zai-coding-plan"))
        #expect(!CLI.openCodeSignedIn(stored, provider: "openai") && !CLI.openCodeSignedIn("[]", provider: "openai"))
        #expect(!CLI.openCodeSignedIn("[{\"id\":\"zai-coding-plan\",\"connections\":[{\"type\":\"env\",\"name\":\"ZHIPU_API_KEY\"}]}]",
                                      provider: "zai-coding-plan"))
        #expect(!CLI.openCodeSignedIn("No authenticated integrations\n", provider: "zai-coding-plan"))

        // The instructions as the agent's whole prompt; read, and nothing else, for it and for all.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(CLI.openCodeConfiguration.utf8)) as? [String: Any])
        let agent = try #require((object["agent"] as? [String: Any])?["blackice"] as? [String: Any])
        #expect(agent["prompt"] as? String == "{file:./instructions.md}" && agent["mode"] as? String == "primary")
        for rules in [object["permission"], agent["permission"]] {
            let rules = try #require(rules as? [String: String])
            #expect(rules["*"] == "deny" && rules.filter { $0.value != "deny" } == ["read": "allow"] && rules.count == 15)
        }
        // The last rule that matches wins: "*" comes first.
        #expect(CLI.openCodeConfiguration.contains("\"permission\":{\"*\":\"deny\",\"read\":\"allow\","))
        #expect(object["autoupdate"] as? Bool == false && object["share"] as? String == "disabled")

        let environment = CLI.openCodeEnvironment(agentHome: "/Users/me/.config/blackice/agent")
        #expect(environment["HOME"] == "/Users/me/.config/blackice/agent/.opencode" && environment["XDG_CONFIG_HOME"] == ".")
        for flag in ["OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_AUTOUPDATE",
                     "OPENCODE_DISABLE_MODELS_FETCH"] {
            #expect(environment[flag] == "1", "\(flag)")
        }
        #expect(CLI.openCodeArguments(model: "zai-coding-plan/glm-5.3-flash")
                == ["run", "--standalone", "--agent", "blackice", "--model", "zai-coding-plan/glm-5.3-flash", CLI.openCodePrompt])

        // The hook goes into blackice.toml and back as it was.
        let program = CLI.agentHook(.opencode, executable: "/Users/me/.opencode/bin/opencode", agentHome: "/Users/me/.config/blackice/agent",
                                    identity: Self.opencode, model: AgentProfile.opencode.defaultModel)
        let text = "mode = \"ask\"\n" + CLI.agentAddition("opencode", identity: Self.opencode, hosts: AgentProfile.opencode.hosts, hook: program)
        let config = try BlackiceConfig(data: Data(text.utf8))
        #expect(config.hooks.first?.program == program && CLI.agentRunning(config.hooks[0])?.name == "opencode")

        // Each provider: its own id, hosts, a model --model takes.
        let providers = AgentProvider.openCode
        #expect(Set(providers.map(\.id)).count == providers.count && providers.allSatisfy { !$0.hosts.isEmpty })
        for provider in providers {
            let profile = AgentProfile.openCode(provider)
            #expect(CLI.validModel(profile.defaultModel) && profile.hosts == provider.hosts && profile.provider == provider)
            #expect(profile.loginArguments == ["auth", "login", "--standalone", provider.id])
        }
        #expect(AgentProfile.opencode.defaultModel == "openai/gpt-6-luna"
                && AgentProfile.opencode.hosts == ["chatgpt.com", "auth.openai.com", "api.openai.com"])

        // The eval runs opencode with the hook's environment, its home put where the agent home is.
        let script = repository.appendingPathComponent("integrations/eval/agents/opencode.sh").path
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", "repo=/r; . \"$1\"; agent_configure; printf '%s\\n' \"${agent_env[@]}\"", "bash", script]
        bash.environment = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        bash.standardOutput = pipe
        try bash.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        bash.waitUntilExit()
        #expect(Set(printed.split(separator: "\n").map(String.init)) == Set(environment.map { "\($0.key)=\($0.value)" }))
    }

    /// The repository's root, from this file's path.
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func claudeCodePieces() throws {
        #expect(CLI.claudeCodeSignedIn("{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"))
        #expect(CLI.claudeCodeSignedIn("A notice first\n{\"loggedIn\": true}\n"))
        #expect(!CLI.claudeCodeSignedIn("{\"loggedIn\": false}") && !CLI.claudeCodeSignedIn("Not logged in") && !CLI.claudeCodeSignedIn(""))

        // Read is its only tool, and the hook goes into blackice.toml and back as it was.
        let home = "/Users/Jane Doe/.config/blackice/agent"
        let arguments = CLI.claudeCodeArguments(model: "haiku")
        #expect(arguments.starts(with: ["-p", "--restricted", "--safe-mode", "--tools", "Read"]))
        #expect(arguments.contains("haiku") && CLI.claudeCodeArguments(model: "sonnet").contains("sonnet"))
        // The instructions the daemon writes into the event's directory, its working directory.
        #expect(arguments.suffix(3) == ["--system-prompt-file", "instructions.md", CLI.claudeCodePrompt])
        #expect(AgentInstructions.claudeCode.files.map(\.path) == ["instructions.md"])
        let program = CLI.agentHook(.claudeCode, executable: "/Users/Jane Doe/.local/bin/claude", agentHome: home, identity: Self.claude,
                                    model: AgentProfile.claudeCode.defaultModel)
        let text = "mode = \"ask\"\n" + CLI.agentAddition("claude-code", identity: Self.claude, hosts: ["api.anthropic.com"], hook: program)
        let config = try BlackiceConfig(data: Data(text.utf8))
        #expect(config.hooks.first?.program == program && program.eventOnStdin == false)
        #expect(CLI.agentRunning(config.hooks[0])?.name == "claude-code")
        #expect(AgentProfile.known.map(\.name) == ["fx", "claude-code", "codex", "opencode"])
        #expect(try adapter("claude-code").contains("agent_stdin=none"))
    }

    /// integrations/eval/agents/NAME.sh, which runs an agent as its hook does.
    private func adapter(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("integrations/eval/agents/\(name).sh"),
                   encoding: .utf8)
    }

    /// The eval runs each agent with its hook's arguments, in the same order, and the hook's model
    /// as the default of MODEL.
    @Test(arguments: AgentProfile.known.map(\.name))
    func theEvalRunsTheHooksArguments(_ name: String) throws {
        let profile = try #require(AgentProfile.known.first { $0.name == name })
        let text = try adapter(name)
        var rest = Substring(text)
        for argument in profile.askArguments("/Users/me/.config/blackice/agent", profile.defaultModel) {
            // In double quotes, or in single quotes when it holds some.
            let words = argument == profile.defaultModel ? ["\"${MODEL:-\(argument)}\""] : ["\"" + argument + "\"", "'" + argument + "'"]
            let range = try #require(words.compactMap { rest.range(of: $0) }.min { $0.lowerBound < $1.lowerBound },
                                     "\(argument) is not in the eval's arguments for \(name)")
            rest = rest[range.upperBound...]
        }
        #expect(text.contains("agent_stdin=none") == !profile.eventOnStdin)
    }

    @Test func aModelOfYourOwn() throws {
        #expect(try CLI.parse(["agent", "connect", "fx", "--model", "openai/gpt-6-luna"])
                == .connectAgent(name: "fx", configPath: nil, model: "openai/gpt-6-luna"))
        for good in ["haiku", "sonnet[1m]", "anthropic/claude-haiku-5.5", "claude-haiku-5-5@20261001", "gpt-6-luna"] {
            #expect(CLI.validModel(good), "\(good)")
        }
        for bad in ["-x", "--model", "", "a b", "a;b", "a\nb", "é", String(repeating: "a", count: 101), "$(id)", "'q'"] {
            #expect(!CLI.validModel(bad), "\(bad)")
            #expect(throws: UsageError.self, "\(bad)") { try CLI.parse(["agent", "connect", "fx", "--model", bad]) }
        }
        let fx = AgentProfile.fx.askArguments("/h", "openai/gpt-6-luna")
        #expect(fx == ["ask", "--no-save", "--no-color", "--model", "openai/gpt-6-luna", "--system", CLI.fxSystemPrompt,
                       AgentProfile.prompt])
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
        #expect(result.stdout.contains("  Sign fx in for blackice, in its own home (~/.config/blackice/agent), apart from yours."))
        #expect(result.stdout.contains("  ✓ reads files only: no shell, no edits, no web"))

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
            args = ["ask", "--no-save", "--no-color", "--model", "anthropic/claude-haiku-5.5", "--system", "\(CLI.fxSystemPrompt)", "\(AgentProfile.prompt)"]
            env = ["FX_DISABLE_KEYCHAIN=1", "HOME=\(agent)"]
            instructions = "fx"

            """))
        #expect(system.texts == [written] && system.agentInstalls == 1)

        // One line per step, under one title, and the start's own lines at the end.
        #expect(result.stdout == [
            "Connecting fx",
            "  ✓ /opt/fake/fx (com.vercel.fx, team JW6Y669B67)",
            "  Sign fx in for blackice, in its own home (~/.config/blackice/agent), apart from yours.",
            "  " + AgentProfile.fx.loginHint,
            "  ✓ signed in",
            "  ✓ reads files only: no shell, no edits, no web",
            "  Testing with anthropic/claude-haiku-5.5 on a sample connection…",
            "  ✓ approved it in 14 s",
            "  ✓ rule: fx may reach ai-gateway.vercel.sh, vercel.com and api.vercel.com in every mode",
            "  ✓ hook: fx answers each connection that waits",
            "  ✓ timeout_seconds = 60, time for fx to answer",
            "  ✓ saved ~/.config/blackice/blackice.toml",
            "",
            "(started)",
        ])

        // Again: nothing to add, no sign-in, no question; it loads the same file.
        let again = connect(home, config: config, mac: mac, system: system)
        #expect(again.status == 0, "\(again.stderr)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written)
        #expect(mac.logins.count == 1 && system.texts == [written, written])
        #expect(again.stdout.contains("  ✓ ~/.config/blackice/blackice.toml has fx's rule and hook already"))
        #expect(!again.stdout.contains { $0.contains("saved") })

        // Another model: the same hook, in its place, with that model in its args.
        let other = connect(home, config: config, mac: mac, system: system,
                            arguments: ["agent", "connect", "fx", "--config", config, "--model", "openai/gpt-6-luna"])
        #expect(other.status == 0, "\(other.stderr)")
        let switched = try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config)))
        #expect(switched.hooks.count == 1 && switched.hooks[0].line == loaded.hooks[0].line)
        #expect(switched.hooks[0].program?.arguments == AgentProfile.fx.askArguments(Self.agent(home), "openai/gpt-6-luna"))
        #expect(other.stdout.contains("  Testing with openai/gpt-6-luna on a sample connection…"))
        #expect(other.stdout.contains("  ✓ hook on line \(loaded.hooks[0].line): now fx with openai/gpt-6-luna"))
        #expect(mac.hookRuns.last?.program?.arguments.contains("openai/gpt-6-luna") == true)
    }

    @Test func noAnswerLeavesTheFileAlone() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let system = Loading()
        let silent = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: nil),
                             system: system)
        #expect(silent.status == ExitCode.software)
        #expect(silent.stderr.first == "  fx exited with status 0 and no answer, so blackice.toml was left as it was.")
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
        #expect(unfunded.stderr.first == "  fx exited with status 1 and no answer, so blackice.toml was left as it was.")
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
                == "  fx exited with status 1 and no answer, so blackice.toml was left as it was.")
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
        #expect(declined.stdout.last == "fx is ready. When you want it answering: blackice mode ask")

        // The end of input at that question is no, the default: it loads as it is too.
        let ended = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: Self.approve),
                            system: system)
        #expect(ended.status == 0 && system.texts.count == 2)
        #expect(ended.stdout.last == "fx is ready. When you want it answering: blackice mode ask")
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
        #expect(declined.stderr == ["  fx is not installed. Install it (https://github.com/vercel-labs/fx), " +
                                    "then: blackice agent connect fx --config ~/.config/blackice/blackice.toml"])
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)

        // An installer that leaves no fx behind.
        let failing = FakeAgentMac(signedIn: false, answer: Self.approve)
        let broken = AgentMachine(findExecutables: { _, _ in [] }, runAttached: failing.machine.runAttached,
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
        #expect(result.stdout.contains("  ✓ /opt/fake/fx (com.vercel.fx, team JW6Y669B67)"))
        #expect(try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))).mode == .ask)
    }

    /// A development build first on PATH (`fx upgrade --channel dev` builds are ad hoc signed):
    /// a signed fx further on is used, or else blackice installs fx's release for itself, apart
    /// from the person's own and off their PATH, and uses that.
    @Test func usesASignedFxBesideADevelopmentBuild() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let installer = "curl -fsSL https://fx.sh/setup.sh | bash"
        let bin = Self.agent(home) + "/bin"
        func hook() throws -> HookProgram? {
            try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))).hooks.first?.program
        }

        // A signed fx further on PATH: no question, no install.
        let both = FakeAgentMac(signedIn: true, answer: Self.approve)
        both.found = ["/opt/dev/fx", "/opt/fake/fx"]
        let first = connect(home, config: config, mac: both, system: Loading(), answers: ["n"])
        #expect(first.status == 0, "\(first.stderr)")
        #expect(first.stdout.contains("  /opt/dev/fx is unsigned or ad hoc signed, so blackice uses /opt/fake/fx."))
        #expect(both.installs.isEmpty)
        #expect(try hook() == Self.program(home))
        try Data(text.utf8).write(to: URL(fileURLWithPath: config))

        // Only the development build, and no to the install: nothing runs and nothing changes.
        let declining = FakeAgentMac(signedIn: true, answer: Self.approve)
        declining.found = ["/opt/dev/fx"]
        let declined = connect(home, config: config, mac: declining, system: Loading(), answers: ["n"])
        #expect(declined.status == ExitCode.unavailable && declining.installs.isEmpty)
        #expect(declined.stdout.contains("  /opt/dev/fx is unsigned or ad hoc signed, as development builds are, so no rule can name it."))
        #expect(declined.stderr == ["  /opt/dev/fx is unsigned or ad hoc signed, so a rule cannot name it."])
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)

        // An install that leaves no signed fx there.
        let failing = FakeAgentMac(signedIn: true, answer: Self.approve)
        failing.found = ["/opt/dev/fx"]
        failing.privateInstallWorks = false
        let failed = connect(home, config: config, mac: failing, system: Loading(), answers: [""])
        #expect(failed.status == ExitCode.unavailable && failing.privateInstalls.count == 1)
        #expect(failed.stderr.first == "  fx's installer exited with status 0, and no signed fx is in")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)

        // Enter installs fx's release in the agent home's bin folder, with that folder on PATH so
        // setup.sh leaves the shell's startup file alone, and the hook starts that copy.
        let mac = FakeAgentMac(signedIn: true, answer: Self.approve)
        mac.found = ["/opt/dev/fx"]
        let result = connect(home, config: config, mac: mac, system: Loading(), answers: ["", "n"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(mac.installs == [["-o", "pipefail", "-c", installer]])
        #expect(mac.privateInstalls == [["FX_INSTALL_DIR": bin, "PATH": bin + ":/usr/bin:/bin:/usr/sbin:/sbin"]])
        #expect(result.stdout.contains("  /opt/dev/fx is unsigned or ad hoc signed, so blackice uses ~/.config/blackice/agent/bin/fx."))
        #expect(try hook() == Self.program(home, path: bin + "/fx"))
        let mode = try FileManager.default.attributesOfItem(atPath: bin)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Connecting again finds that copy: no question, no install, the same hook.
        let again = FakeAgentMac(signedIn: true, answer: Self.approve)
        again.found = ["/opt/dev/fx"]
        again.privateCopy = true
        let second = connect(home, config: config, mac: again, system: Loading(), answers: ["n"])
        #expect(second.status == 0 && again.installs.isEmpty)
        #expect(second.stdout.contains("  ✓ ~/.config/blackice/blackice.toml has fx's rule and hook already"))
        #expect(try hook() == Self.program(home, path: bin + "/fx"))
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
        // Both as written: what the questions and agent connect wrote wins over an earlier switch.
        #expect(system.asWritten == [true, true])
        #expect(try BlackiceConfig(data: Data(system.texts[0].utf8)).mode == .acceptAll)
        let final = try BlackiceConfig(data: Data(system.texts[1].utf8))
        #expect(final.mode == .ask && final.hooks.count == 1 && final.allowRule(for: Self.fx, host: "ai-gateway.vercel.sh") != nil)
        #expect(try String(contentsOfFile: config, encoding: .utf8) == system.texts[1])
        #expect(mac.installs.count == 1 && mac.logins.count == 1 && system.agentInstalls == 1 && system.modes.isEmpty)
        for heading in ["1 · Pick a mode", "4 · Connect fx"] {
            #expect(out.items.contains(heading), "\(heading)")
        }
        #expect(out.items.contains("  ✓ blackice is on in accept-all mode until fx is set up"))
        #expect(!out.items.contains { $0.hasPrefix("Connecting fx") || $0.contains("Switch to ask mode") })
    }

    @Test func aFailedSignInIsOfferedAgain() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config) = try setUp(text)
        defer { removeTree(home) }
        let retried = FakeAgentMac(signedIn: false, answer: Self.approve)
        retried.loginFailures = 1
        let result = connect(home, config: config, mac: retried, system: Loading(), answers: ["", "n"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(retried.logins.count == 2 && result.stdout.contains("  ✓ signed in"))

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
        #expect(result.stdout.contains("  In ask mode fx's own connections would wait, so accept-all until it is set up."))
        #expect(try BlackiceConfig(data: Data(system.texts.last!.utf8)).mode == .ask)
    }

    /// A setup that switched to accept-all and stops before it loads the file switches back,
    /// whatever stopped it, instead of leaving every connection let through.
    @Test func aSetupThatStopsLeavesAcceptAll() throws {
        let (home, config) = try setUp("mode = \"ask\"\ntimeout_seconds = 60\n")
        defer { removeTree(home) }
        let back = "The setup did not finish, so blackice goes back to ask mode."

        // fx gives no answer in the test.
        let silent = Loading()
        silent.running = .ask
        let unanswered = connect(home, config: config, mac: FakeAgentMac(signedIn: true, answer: nil),
                                 system: silent)
        #expect(unanswered.status == ExitCode.software)
        #expect(silent.modes == [.acceptAll, .ask] && silent.running == .ask && silent.texts.isEmpty)
        #expect(unanswered.stdout.contains(back))

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
        let back = "The setup did not finish, so blackice goes back to ask mode."
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
        let retry = " To finish it: blackice agent connect fx --config ~/.config/blackice/blackice.toml"
        let without = "To filter without an agent: blackice mode ask, or blackice mode block-all"

        let declined = try firstStart(["n"])   // do not install fx
        #expect(declined.status == ExitCode.unavailable)
        #expect(declined.system.texts.count == 1 && declined.system.modes.isEmpty && declined.system.running == .acceptAll)
        #expect(Array(declined.stderr.suffix(4)) == [
            "", "blackice is on in accept-all mode: every connection goes through.",
            "The fx setup failed, as above." + retry, without,
        ])
        #expect(!declined.stdout.contains { $0.hasPrefix("The setup did not finish") })
        // The file keeps the mode picked, for agent connect to load once fx is set up.
        #expect(declined.written.mode == .ask)

        let interrupted = try firstStart([Self.controlC])
        #expect(interrupted.status == ExitCode.interrupted && interrupted.system.modes.isEmpty)
        #expect(Array(interrupted.stderr.suffix(5)) == [
            "  Interrupted, so the setup stops here.",
            "", "blackice is on in accept-all mode: every connection goes through.",
            "The fx setup was interrupted." + retry, without,
        ])
    }

    /// The first start offers Codex and opencode as well, and sets the one picked up as agent connect
    /// does: in accept-all until it works, then the file as written, in ask mode. opencode's provider
    /// is asked in its step. blackice cannot install Codex, so without it blackice stays in accept-all.
    @Test func startPicksCodexOrOpenCode() throws {
        func firstStart(_ picks: [[Int]], machine: AgentMachine, identity: SigningIdentity,
                        choices: Recorder<Choice> = Recorder<Choice>())
            throws -> (status: Int32, system: Loading, stdout: [String], stderr: [String], home: URL, written: String) {
            let home = try makePrivateDirectory()
            defer { removeTree(home) }
            let config = home.path + "/.config/blackice/blackice.toml"
            let system = Loading()
            var picks = picks
            let interaction = Interaction(
                ask: { _ in nil }, createFile: CLI.createFile,
                identify: { $0.hasPrefix("/opt/fake/") ? identity : nil },
                fileExists: { FileManager.default.fileExists(atPath: $0) }, home: home.path, version: nil,
                choose: { choice in choices.append(choice); return picks.isEmpty ? nil : picks.removeFirst() })
            let out = Recorder<String>(), err = Recorder<String>()
            let status = CLI.run(["start", "--config", config], stdout: { out.append($0) }, stderr: { err.append($0) },
                                 system: system, interaction: interaction, agents: machine)
            return (status, system, out.items, err.items, home, try String(contentsOfFile: config, encoding: .utf8))
        }
        let approves = "com.microsoft.VSCode -> update.code.visualstudio.com: its update server\napprove 12h\n"

        // ask, Codex answers, no apps.
        let codexMac = FakeCodexMac(signedIn: false, printed: approves)
        let codex = try firstStart([[1], [2], []], machine: codexMac.machine, identity: Self.codex)
        #expect(codex.status == 0, "\(codex.stderr)")
        #expect(codex.system.texts.count == 2 && codex.system.agentInstalls == 1 && codex.system.modes.isEmpty)
        #expect(try BlackiceConfig(data: Data(codex.system.texts[0].utf8)).mode == .acceptAll)
        let codexFinal = try BlackiceConfig(data: Data(codex.system.texts[1].utf8))
        #expect(codexFinal.mode == .ask && codexFinal.hooks.map(\.program) == [Self.codexProgram(codex.home)])
        #expect(codex.written == codex.system.texts[1] && codexMac.logins.count == 1)
        #expect(codex.stdout.contains("4 · Connect codex") && codex.stdout.contains("  ✓ approved it in 5 s"))

        // ask, opencode answers, no apps, then the OpenAI provider in its step.
        let openCodeMac = FakeOpenCodeMac(printed: approves)
        let asked = Recorder<Choice>()
        let openCode = try firstStart([[1], [3], [], [0]], machine: openCodeMac.machine, identity: Self.opencode, choices: asked)
        #expect(openCode.status == 0, "\(openCode.stderr)")
        #expect(asked.items.map(\.prompt) == ["  How should blackice treat new connections?", "  Who answers the connections that wait?",
                                              "  Which apps may connect anywhere, in every mode?",
                                              "  Which provider should opencode decide with?"])
        let openCodeFinal = try BlackiceConfig(data: Data(openCode.system.texts[1].utf8))
        #expect(openCodeFinal.mode == .ask && openCode.system.texts.count == 2)
        #expect(openCodeFinal.hooks.map(\.program) == [Self.openCodeProgram(openCode.home, model: "openai/gpt-6-luna")])
        for host in AgentProvider.openCode[0].hosts { #expect(openCodeFinal.allowRule(for: Self.opencode, host: host) != nil) }
        #expect(openCodeMac.logins == [["auth", "login", "--standalone", "openai"]])
        #expect(openCode.stdout.contains("4 · Connect opencode"))

        // Codex is not installed: blackice stays in accept-all, and says how to finish.
        let missing = FakeCodexMac(signedIn: false, printed: approves)
        missing.installed = false
        let stopped = try firstStart([[1], [2], []], machine: missing.machine, identity: Self.codex)
        #expect(stopped.status == ExitCode.unavailable)
        #expect(stopped.system.texts.count == 1 && stopped.system.running == .acceptAll && stopped.system.modes.isEmpty)
        #expect(stopped.stderr.contains("  codex is not installed. Install it (\(AgentProfile.codex.installHint)), then: " +
                                        "blackice agent connect codex --config ~/.config/blackice/blackice.toml"))
        #expect(Array(stopped.stderr.suffix(3)) == [
            "blackice is on in accept-all mode: every connection goes through.",
            "The codex setup failed, as above. To finish it: blackice agent connect codex --config ~/.config/blackice/blackice.toml",
            "To filter without an agent: blackice mode ask, or blackice mode block-all",
        ])
        #expect(try BlackiceConfig(text: stopped.written).mode == .ask)
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
        #expect(merged.stdout.contains("  ~/.config/blackice/blackice.toml changed meanwhile; the additions go on top."))
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
            && other.stderr.first == "blackice: agent connect takes fx, claude-code, codex or opencode")

        let missing = connect(home, config: home.path + "/none.toml", mac: mac, system: Loading())
        #expect(missing.status == ExitCode.unreadable)
        #expect(missing.stderr.last == "Set blackice up first, then connect fx: blackice start --config ~/none.toml")

        var noFx = mac.machine
        noFx = AgentMachine(findExecutables: { _, _ in [] }, runAttached: noFx.runAttached, runCaptured: noFx.runCaptured,
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
        #expect(result.stdout.contains("  ✓ hook on line 10: now starts fx directly"))
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
        #expect(CLI.testAnswer(ran(.exited(status: 0), ""), seconds: 120) == .none("exited with status 0 and no answer"))
        #expect(CLI.testAnswer(ran(.timedOut(signal: 15), "deny"), seconds: 120) == .none("gave no answer in 120 s"))
        #expect(CLI.testAnswer(ran(.dropped(.queueFull), ""), seconds: 120) == .none("did not run (queue_full)"))

        #expect(CLI.settingRootKey("# c\nmode = \"block-all\"\n[[allow]]\nmode = 1\n", "mode", to: "\"ask\"")
            == "# c\nmode = \"ask\"\n[[allow]]\nmode = 1\n")
        #expect(CLI.settingRootKey("# c\n\n[[allow]]\n", "timeout_seconds", to: "60") == "# c\ntimeout_seconds = 60\n\n[[allow]]\n")
        #expect(CLI.listed(["a"]) == "a" && CLI.listed(["a", "b", "c"]) == "a, b and c" && CLI.listed(["a", "b"], or: true) == "a or b")
        #expect(CLI.agentAddition("fx", identity: Self.fx, hosts: [], hook: nil).isEmpty)

        let event = try CLI.sampleAgentEvent()
        try event.validate(now: Date(), maximumWait: TimeInterval(CLI.agentTestSeconds))
        // The hook reads back from blackice.toml as it was written, quotes and backslashes included.
        let program = CLI.agentHook(.fx, executable: "/Users/Jane \"Doe\"/.local/bin/fx",
                                    agentHome: "/Users/Jane \"Doe\"/back\\slash/.config/blackice/agent", identity: Self.fx,
                                    model: AgentProfile.fx.defaultModel)
        let config = try BlackiceConfig(data: Data(("mode = \"ask\"\n" + CLI.agentAddition("fx", identity: Self.fx, hosts: ["vercel.com"],
                                                                                          hook: program)).utf8))
        #expect(config.hooks.first?.program == program && config.allowRule(for: Self.fx, host: "vercel.com") != nil)
        #expect(program.environment == ["HOME": "/Users/Jane \"Doe\"/back\\slash/.config/blackice/agent", "FX_DISABLE_KEYCHAIN": "1"])
    }
}
