import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

/// A Mac with fx at /opt/fake/fx: `status` says signed in once `login` ran, and the hook "decides"
/// by writing what fx would run into the stand-in's answers file.
private final class FakeAgentMac: @unchecked Sendable {
    var signedIn: Bool
    var answer: ((HookEvent) -> String)?
    var logins: [[String: String]] = []
    var hookRuns: [String] = []
    let resources: String

    init(signedIn: Bool, resources: String, answer: ((HookEvent) -> String)?) {
        self.signedIn = signedIn
        self.resources = resources
        self.answer = answer
    }

    var machine: AgentMachine {
        AgentMachine(
            findExecutable: { $0 == "fx" ? "/opt/fake/fx" : nil },
            runAttached: { _, arguments, environment in
                if arguments == ["login", "vercel"] { self.logins.append(environment); self.signedIn = true }
                return 0
            },
            runCaptured: { _, arguments, _ in
                (0, arguments == ["status"] ? "[status] model=x\n[status] auth=\(self.signedIn ? "vercel" : "missing")\n" : "")
            },
            runHook: { run, event, _, _ in
                self.hookRuns.append(run)
                if let answer = self.answer,
                   let start = run.range(of: "PATH=\""), let end = run[start.upperBound...].firstIndex(of: ":") {
                    let standIn = String(run[start.upperBound..<end])
                    try? Data((answer(event) + "\n").utf8).write(to: URL(fileURLWithPath: standIn + "/answers"))
                }
                return HookResult(hookLine: 0, outcome: .exited(status: 0), stderr: "fx: done", stderrTruncated: false,
                                  duration: 14)
            },
            agentResources: resources)
    }
}

private final class Loading: SystemControlling {
    var texts: [String] = []
    var agentInstalls = 0
    func start(configText: String, output: SystemOutput) -> Int32 { texts.append(configText); output.stdout("(started)"); return 0 }
    func stop(output: SystemOutput) -> Int32 { 0 }
    func status(output: SystemOutput) -> Int32 { 0 }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { 0 }
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
    static let approve: @Sendable (HookEvent) -> String = {
        "approve --app com.microsoft.VSCode --team UBF8T346G9 --host update.code.visualstudio.com --for 1h --token \($0.token)"
    }

    /// A home with blackice.toml and Blackice.app's agent resources next to it.
    private func setUp(_ config: String) throws -> (home: URL, config: String, resources: String) {
        let home = try makePrivateDirectory()
        let folder = home.appendingPathComponent(".config/blackice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("blackice.toml").path
        try Data(config.utf8).write(to: URL(fileURLWithPath: path))
        let skill = home.appendingPathComponent("app-resources/agents/fx/blackice")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# skill\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        return (home, path, home.appendingPathComponent("app-resources/agents").path)
    }

    private func connect(_ home: URL, config: String, mac: FakeAgentMac, system: Loading, answers: [String] = [],
                         arguments: [String]? = nil) -> Connected {
        var script = answers
        let interaction = Interaction(
            ask: { _ in script.isEmpty ? nil : script.removeFirst() }, createFile: CLI.createFile,
            identify: { $0 == "/opt/fake/fx" ? Self.fx : nil }, fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home.path, version: nil)
        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(arguments ?? ["agent", "connect", "fx", "--config", config], stdout: { out.append($0) },
                             stderr: { err.append($0) }, system: system, interaction: interaction, agents: mac.machine)
        return Connected(status: status, stdout: out.items, stderr: err.items)
    }

    @Test func connectsFxEndToEnd() throws {
        let (home, config, resources) = try setUp("""
            mode = "accept-all"     # accept-all, ask or block-all
            timeout_seconds = 10    # in ask mode, no answer in time means deny

            [[allow]]
            app = "com.apple.curl"
            hosts = ["pypi.org"]
            """)
        defer { removeTree(home) }
        let mac = FakeAgentMac(signedIn: false, resources: resources, answer: Self.approve)
        let system = Loading()
        let result = connect(home, config: config, mac: mac, system: system, answers: ["y"])
        #expect(result.status == 0, "\(result.stderr)")

        // Its home: the skill, a sign-in with its own HOME and no keychain, and the rules.
        let agent = home.path + "/.config/blackice/agent"
        #expect(FileManager.default.fileExists(atPath: agent + "/.fx/skills/blackice/SKILL.md"))
        #expect(mac.logins == [["HOME": agent, "FX_DISABLE_KEYCHAIN": "1"]])
        let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: agent + "/.fx/settings.json"))) as? [String: Any])
        #expect(settings["permission_mode"] as? String == "ask")
        let bash = try #require((settings["permission"] as? [String: Any])?["bash"] as? [String: String])
        #expect(bash == ["*": "deny", "blackice approve *": "allow", "blackice deny *": "allow"])
        #expect(try permissions(URL(fileURLWithPath: agent)) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: agent + "/test"))

        // The test ran the hook line with the stand-in first on PATH; the real hook has the app's.
        #expect(mac.hookRuns.count == 1 && mac.hookRuns[0].contains("PATH=\"\(agent)/test/bin:/usr/bin"))
        let written = try String(contentsOfFile: config, encoding: .utf8)
        let loaded = try BlackiceConfig(data: Data(written.utf8))
        #expect(loaded.mode == .ask && loaded.timeoutSeconds == 60)
        #expect(written.contains("mode = \"ask\"".padding(toLength: 24, withPad: " ", startingAt: 0) + "# accept-all, ask or block-all\n"))
        for host in AgentProfile.fx.hosts { #expect(loaded.allowRule(for: Self.fx, host: host) != nil) }
        #expect(loaded.allowRule(for: SigningIdentity(signingID: "com.apple.curl", teamID: nil), host: "pypi.org") != nil)
        #expect(loaded.hooks.map(\.run) == [CLI.fxHookRun(fx: "/opt/fake/fx", agentHome: agent)])
        #expect(loaded.hooks[0].run.hasPrefix("FX_DISABLE_KEYCHAIN=1 PATH=\"/Applications/Blackice.app/Contents/MacOS:/usr/bin"))
        #expect(system.texts == [written] && system.agentInstalls == 1)

        #expect(result.stdout.contains("1 · Find fx"))
        #expect(result.stdout.contains("  ✓ /opt/fake/fx is com.vercel.fx, team JW6Y669B67"))
        #expect(result.stdout.contains("  ✓ fx approved it in 14 s"))
        #expect(result.stdout.contains("  ✓ fx may reach ai-gateway.vercel.sh, vercel.com and api.vercel.com in every mode"))
        #expect(result.stdout.contains("  ✓ timeout_seconds is now 60, so fx has time to answer"))
        #expect(result.stdout.last == "✓ fx answers what no rule covers. See what waits with: blackice pending")

        // Again: nothing to add, no sign-in, no question; it loads the same file.
        let again = connect(home, config: config, mac: mac, system: system)
        #expect(again.status == 0, "\(again.stderr)")
        #expect(try String(contentsOfFile: config, encoding: .utf8) == written)
        #expect(mac.logins.count == 1 && system.texts == [written, written])
        #expect(again.stdout.contains("  fx could already reach its model's hosts."))
        #expect(again.stdout.contains { $0.hasPrefix("  A hook already runs the blackice skill (line ") })
    }

    @Test func noAnswerLeavesTheFileAlone() throws {
        let text = "mode = \"accept-all\"\ntimeout_seconds = 60\n"
        let (home, config, resources) = try setUp(text)
        defer { removeTree(home) }
        let system = Loading()
        let silent = connect(home, config: config, mac: FakeAgentMac(signedIn: true, resources: resources, answer: nil),
                             system: system)
        #expect(silent.status == ExitCode.software)
        #expect(silent.stderr.first == "  fx exited with status 0 and gave no answer, so blackice.toml was left as it was.")
        #expect(silent.stderr.contains("    fx: done"))
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text && system.texts.isEmpty)

        let tokenless = connect(home, config: config, mac: FakeAgentMac(signedIn: true, resources: resources,
                                                                       answer: { _ in "approve --app x --token nope" }), system: system)
        #expect(tokenless.status == ExitCode.software)
        #expect(tokenless.stderr.first == "  fx answered without the event's token, so blackice.toml was left as it was.")

        // Saying no to ask mode loads it as it is.
        let declined = connect(home, config: config, mac: FakeAgentMac(signedIn: true, resources: resources, answer: Self.approve),
                               system: system, answers: ["n"])
        #expect(declined.status == 0)
        #expect(try BlackiceConfig(data: Data(contentsOf: URL(fileURLWithPath: config))).mode == .acceptAll)
        #expect(declined.stdout.last == "✓ fx is ready. When you want it answering: blackice mode ask")
    }

    @Test func refusals() throws {
        let (home, config, resources) = try setUp("mode = \"accept-all\"\n")
        defer { removeTree(home) }
        let mac = FakeAgentMac(signedIn: true, resources: resources, answer: Self.approve)
        let other = connect(home, config: config, mac: mac, system: Loading(), arguments: ["agent", "connect", "claude"])
        #expect(other.status == ExitCode.usage && other.stderr.first?.hasPrefix("blackice agent connect knows fx so far") == true)

        let missing = connect(home, config: home.path + "/none.toml", mac: mac, system: Loading())
        #expect(missing.status == ExitCode.unreadable)
        #expect(missing.stderr.last == "Set blackice up first, then connect fx: blackice start --config ~/none.toml")

        var noFx = mac.machine
        noFx = AgentMachine(findExecutable: { _ in nil }, runAttached: noFx.runAttached, runCaptured: noFx.runCaptured,
                            runHook: noFx.runHook, agentResources: resources)
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

    @Test func pieces() throws {
        #expect(CLI.fitsHookLine("/Users/Jane Doe/.local/bin/fx"))
        for bad in ["fx", "/a\"b", "/a$b", "/a`b", "/a\\b", "/a'b", "/a\nb"] { #expect(!CLI.fitsHookLine(bad)) }

        let merged = try #require(JSONSerialization.jsonObject(with: CLI.fxSettings(Data(#"{"model":"m","permission_mode":"auto"}"#.utf8))) as? [String: Any])
        #expect(merged["model"] as? String == "m" && merged["permission_mode"] as? String == "ask")
        #expect(throws: (any Error).self) { try CLI.fxSettings(Data("[1]".utf8)) }
        #expect((try? CLI.fxSettings(nil)) != nil && (try? CLI.fxSettings(Data("\n".utf8))) != nil)

        #expect(!CLI.fxSignedIn("[status] auth=missing\n") && !CLI.fxSignedIn("nothing"))
        #expect(CLI.fxSignedIn("[status] model=x\n[status] auth=vercel"))

        #expect(CLI.testAnswer("", token: testToken) == .none)
        #expect(CLI.testAnswer("deny --app a --host h --token \(testToken)\n", token: testToken) == .denied)
        #expect(CLI.testAnswer("approve --token \(testToken)\napprove --token \(testToken)\n", token: testToken) == .wrong("answered 2 times"))
        #expect(CLI.testAnswer("pending --token \(testToken)", token: testToken) == .wrong("ran blackice pending"))

        #expect(CLI.settingRootKey("# c\nmode = \"block-all\"\n[[allow]]\nmode = 1\n", "mode", to: "\"ask\"")
            == "# c\nmode = \"ask\"\n[[allow]]\nmode = 1\n")
        #expect(CLI.settingRootKey("# c\n\n[[allow]]\n", "timeout_seconds", to: "60") == "# c\ntimeout_seconds = 60\n\n[[allow]]\n")
        #expect(CLI.listed(["a"]) == "a" && CLI.listed(["a", "b", "c"]) == "a, b and c")
        #expect(CLI.agentAddition("fx", identity: Self.fx, hosts: [], run: nil).isEmpty)

        let event = try CLI.sampleAgentEvent()
        try event.validate(now: Date(), maximumWait: TimeInterval(CLI.agentTestSeconds))
        // The hook line fits in blackice.toml as the parser reads it.
        let run = CLI.fxHookRun(fx: "/Users/Jane Doe/.local/bin/fx", agentHome: "/Users/Jane Doe/.config/blackice/agent")
        let config = try BlackiceConfig(data: Data(("mode = \"ask\"\n" + CLI.agentAddition("fx", identity: Self.fx, hosts: ["vercel.com"], run: run)).utf8))
        #expect(config.hooks.first?.run == run && config.allowRule(for: Self.fx, host: "vercel.com") != nil)
    }
}
