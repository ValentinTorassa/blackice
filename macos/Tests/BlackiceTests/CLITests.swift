import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

private struct Run {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func run(_ arguments: [String], files: [String: Data] = [:],
                 system: SystemControlling = UnsignedSystem()) -> Run {
    let out = Recorder<String>(), err = Recorder<String>()
    let status = CLI.run(arguments, stdout: { out.append($0) }, stderr: { err.append($0) }, readFile: { path in
        guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }, system: system)
    return Run(status: status, stdout: out.items.joined(separator: "\n"), stderr: err.items.joined(separator: "\n"))
}

/// Stands in for NESystemControl: records each call and answers with a fixed status.
private final class FakeSystem: SystemControlling {
    var calls: [String] = []
    let answer: Int32

    init(status: Int32 = 0) { answer = status }

    func start(configText: String, output: SystemOutput) -> Int32 {
        calls.append("start " + configText)
        output.stdout("started")
        return answer
    }

    func stop(output: SystemOutput) -> Int32 { calls.append("stop"); return answer }
    func status(output: SystemOutput) -> Int32 { calls.append("status"); output.stdout("filter: enabled"); return answer }

    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 {
        calls.append("mode " + mode.rawValue)
        output.stderr("mode refused")
        return answer
    }

    func setMode(_ mode: Mode, answerer: Answerer?, output: SystemOutput) -> Int32 {
        guard let answerer else { return setMode(mode, output: output) }
        calls.append("mode \(mode.rawValue) --agent \(answerer.name)")
        return answer
    }

    func pending(output: SystemOutput) -> Int32 { calls.append("pending"); return answer }

    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 {
        calls.append("\(request.kind.rawValue) \(request.app.identity?.label ?? "?") \(request.host) " +
                     "\(request.seconds.map(String.init) ?? "-") \(request.authorization.rawValue)" +
                     (request.script.map { " script=\($0)" } ?? ""))
        return answer
    }

    func runDaemon(output: SystemOutput) -> Int32 { calls.append("daemon"); return answer }
    func installAgent(output: SystemOutput) -> Int32 { calls.append("agent install"); return answer }
    func uninstallAgent(output: SystemOutput) -> Int32 { calls.append("agent uninstall"); return answer }
}

private func usageError(_ arguments: [String]) -> String? {
    do {
        _ = try CLI.parse(arguments)
        return nil
    } catch {
        return "\(error)"
    }
}

struct ParseTests {
    @Test func simpleCommands() throws {
        #expect(try CLI.parse(["start"]) == .start(configPath: nil))
        #expect(try CLI.parse(["start", "--config", "a.toml"]) == .start(configPath: "a.toml"))
        #expect(try CLI.parse(["start", "--config=/etc/n.toml"]) == .start(configPath: "/etc/n.toml"))
        #expect(try CLI.parse(["stop"]) == .stop)
        #expect(try CLI.parse(["status"]) == .status)
        #expect(try CLI.parse(["pending"]) == .pending)
        #expect(try CLI.parse(["--help"]) == .help())
        #expect(try CLI.parse(["help", "mode"]) == .help("mode"))
        #expect(try CLI.parse(["approve", "--help"]) == .help("approve"))
        #expect(throws: UsageError.self) { try CLI.parse(["help", "nothing"]) }
        #expect(try CLI.parse(["validate", "blackice.toml"]) == .validate(path: "blackice.toml"))
        for mode in Mode.allCases { #expect(try CLI.parse(["mode", mode.rawValue]) == .mode(mode)) }
        #expect(try CLI.parse(["mode", "ask", "--agent", "claude-code"]) == .mode(.ask, answerer: .agent(.claudeCode)))
        #expect(try CLI.parse(["mode", "ask", "--agent=you"]) == .mode(.ask, answerer: .you))
    }

    @Test func approveDefaultsAndForms() throws {
        let approval = try CLI.parse(["approve", "--app", "com.example.tool", "--team=ABCDE12345", "--host", "Example.COM."])
        let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
        #expect(approval == .approve(Approval(identity: tool, host: "example.com", seconds: 3600)))
        let apple = try CLI.parse(["approve", "--app", "com.apple.curl", "--host", "example.com", "--for", "10m"])
        let curl = AppIdentity.signed(SigningIdentity(signingID: "com.apple.curl", teamID: nil))
        #expect(apple == .approve(Approval(identity: curl, host: "example.com", seconds: 600)))
        let denial = try CLI.parse(["deny", "--host", "example.com", "--app", "com.example.tool"])
        let untrusted = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: nil))
        #expect(denial == .deny(Denial(identity: untrusted, host: "example.com")))
        // A person's answer always: the request carries no token.
        for command in [approval, apple, denial] {
            switch command {
            case .approve(let parsed): #expect(parsed.requests.allSatisfy { $0.authorization == .touchID && $0.token == nil })
            case .deny(let parsed): #expect(parsed.request.authorization == .touchID && parsed.request.token == nil)
            default: Issue.record("\(command)")
            }
        }
    }

    /// A connection with no name is asked about by its address, and `--host` takes one, in the
    /// form the extension names it.
    @Test func hostMayBeAnIPAddress() throws {
        let ssh = AppIdentity.signed(SigningIdentity(signingID: "com.apple.ssh", teamID: nil))
        let forms: [(String, String)] = [
            ("100.66.32.75", "100.66.32.75"), ("FD7A:115C:A1E0:0:0:0:0:1", "fd7a:115c:a1e0::1"),
            ("::ffff:100.66.32.75", "100.66.32.75"), ("fe80::1%lo0", "fe80::1%\(if_nametoindex("lo0"))"),
        ]
        for (raw, host) in forms {
            #expect(try CLI.parse(["approve", "--app", "com.apple.ssh", "--host", raw, "--for", "1h"])
                    == .approve(Approval(identity: ssh, host: host, seconds: 3600)), "\(raw)")
            #expect(try CLI.parse(["deny", "--app", "com.apple.ssh", "--host", raw]) == .deny(Denial(identity: ssh, host: host)))
        }
        let ranges = "with no wildcards, ranges or leading zeros"
        let cases: [(String, String)] = [
            ("010.0.0.1", "leading zeros"), ("10.1", ranges), ("100.64.0.0/10", ranges), ("2001:db8::/32", ranges),
            ("fe80::1", "link-local address's interface"), ("2001:db8::1%en0", ranges),
        ]
        for (raw, fragment) in cases {
            let message = usageError(["approve", "--app", "com.apple.ssh", "--host", raw])
            #expect(message?.contains(fragment) == true, "\(raw): \(message ?? "parsed")")
        }
    }

    /// Hooks answer on their stdout since 0.4.0, so `--token` is gone, with a message that says so.
    @Test func approveAndDenyTakeNoToken() {
        let token = "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys"
        for arguments in [["approve", "--app", "com.a", "--host", "example.com", "--token", token],
                          ["approve", "--app", "com.a", "--host", "example.com", "--token=\(token)"],
                          ["deny", "--cdhash", testCDHash, "--host", "example.com", "--token", token]] {
            #expect(throws: UsageError.self) { try CLI.parse(arguments) }
            do {
                _ = try CLI.parse(arguments)
            } catch {
                #expect("\(error)".contains("takes no --token: a hook answers with its last line of output"))
            }
        }
    }

    @Test func cdhashNamesAdHocCode() throws {
        let upper = testCDHash.uppercased()
        let approval = try CLI.parse(["approve", "--cdhash", upper, "--host", "example.com", "--for", "30s"])
        #expect(approval == .approve(Approval(identity: .cdhash(testCDHash), host: "example.com", seconds: 30)))
        let denial = try CLI.parse(["deny", "--cdhash=\(testCDHash)", "--host", "example.com"])
        #expect(denial == .deny(Denial(identity: .cdhash(testCDHash), host: "example.com")))
        if case .approve(let parsed) = approval, let request = parsed.requests.first {
            #expect(parsed.requests.count == 1)
            #expect(request.app == AppReference(signingID: nil, teamID: nil, cdhash: testCDHash))
            #expect(request.authorization == .touchID)
            #expect(throws: Never.self) { try request.validate(now: Date()) }
        }
    }

    /// One command, and one Touch ID, for an app's several hosts: a CLI in an interpreter reaches a
    /// sign-in host, an API and a mail server, and `pending` lists them together (6 November 2026).
    @Test func approveTakesSeveralHosts() throws {
        let parsed = try CLI.parse(["approve", "--cdhash", testCDHash, "--host", "oauth2.googleapis.com",
                                    "--host=Login.MicrosoftOnline.com.", "--for", "10m", "--host", "100.66.32.75"])
        let hosts = ["oauth2.googleapis.com", "login.microsoftonline.com", "100.66.32.75"]
        #expect(parsed == .approve(Approval(identity: .cdhash(testCDHash), hosts: hosts, seconds: 600)))
        guard case .approve(let approval) = parsed else { Issue.record("\(parsed)"); return }
        #expect(approval.requests.map(\.host) == hosts)
        #expect(approval.requests.allSatisfy {
            $0.kind == .approve && $0.identity == .cdhash(testCDHash) && $0.seconds == 600 && $0.authorization == .touchID &&
                $0.token == nil && (try? $0.validate(now: Date())) != nil
        })

        let sixteen = (1...16).flatMap { ["--host", "h\($0).example.com"] }
        if case .approve(let most) = try CLI.parse(["approve", "--app", "com.a"] + sixteen) {
            #expect(most.hosts.count == CLI.maximumApprovalHosts && most.hosts.last == "h16.example.com")
        } else {
            Issue.record("sixteen hosts did not parse as an approval")
        }
        let cases: [([String], String)] = [
            (["approve", "--app", "com.a"] + sixteen + ["--host", "h17.example.com"], "approve: at most 16 --host at once"),
            (["approve", "--app", "com.a", "--host", "example.com", "--host", "EXAMPLE.com."], "approve: --host example.com given twice"),
            (["approve", "--app", "com.a", "--host", "example.com", "--host", "*.example.com"], "with no wildcards"),
            (["approve", "--app", "com.a", "--host", "example.com", "--host"], "approve: --host needs a value"),
            (["approve", "--app", "com.a", "--host", "a.example.com", "--host=", "--for", "1h"], "approve: --host needs a value"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "1h", "--for", "2h"], "approve: --for given twice"),
            (["approve", "--app", "com.a", "--for", "1h"], "approve needs --host"),
            // deny still names one host.
            (["deny", "--app", "com.a", "--host", "a.example.com", "--host", "b.example.com"], "deny: --host given twice"),
        ]
        for (arguments, fragment) in cases {
            let message = usageError(arguments)
            #expect(message?.contains(fragment) == true, "\(arguments): \(message ?? "parsed")")
        }
    }

    @Test func approveAndDenyCanNameOneScript() throws {
        let python = AppIdentity.cdhash(testCDHash)
        let parsed = try CLI.parse(["approve", "--cdhash", testCDHash, "--host", "sts.amazonaws.com", "--for", "24h",
                                    "--script", "/opt/homebrew/bin/aws"])
        #expect(parsed == .approve(Approval(identity: python, hosts: ["sts.amazonaws.com"], seconds: 86_400,
                                            script: "/opt/homebrew/bin/aws")))
        guard case .approve(let approval) = parsed else { Issue.record("\(parsed)"); return }
        #expect(approval.requests.allSatisfy { $0.scope == .script("/opt/homebrew/bin/aws") && (try? $0.validate(now: Date())) != nil })
        let denied = try CLI.parse(["deny", "--cdhash", testCDHash, "--host", "pypi.org", "--script=-m pip"])
        #expect(denied == .deny(Denial(identity: python, host: "pypi.org", script: "-m pip")))
        if case .deny(let denial) = denied { #expect(denial.request.scope == .script("-m pip")) }
        // Without --script, a person's answer covers every script, as before.
        if case .deny(let denial) = try CLI.parse(["deny", "--cdhash", testCDHash, "--host", "pypi.org"]) {
            #expect(denial.request.scope == .any)
        }
        let cases: [([String], String)] = [
            (["approve", "--cdhash", testCDHash, "--host", "pypi.org", "--script", "tool.py"], "--script takes the script's full path"),
            (["deny", "--cdhash", testCDHash, "--host", "pypi.org", "--script", "-m"], "--script takes the script's full path"),
            (["approve", "--cdhash", testCDHash, "--host", "pypi.org", "--script", "/a.py", "--save"], "--script and --save do not go together"),
            (["approve", "--cdhash", testCDHash, "--host", "pypi.org", "--script", "/a.py", "--script", "/b.py"], "--script given twice"),
        ]
        for (arguments, fragment) in cases {
            let message = usageError(arguments)
            #expect(message?.contains(fragment) == true, "\(arguments): \(message ?? "parsed")")
        }
        let system = FakeSystem()
        #expect(run(["approve", "--cdhash", testCDHash, "--host", "a.example.com", "--host", "b.example.com", "--for", "5m",
                     "--script", "/opt/homebrew/bin/aws"], system: system).status == 0)
        #expect(system.calls == ["approve cdhash/\(testCDHash) a.example.com 300 touch_id script=/opt/homebrew/bin/aws",
                                 "approve cdhash/\(testCDHash) b.example.com 300 touch_id script=/opt/homebrew/bin/aws"])
    }

    @Test func pendingBindsItsCommandsToTheScript() throws {
        let python = AppReference(signingID: nil, teamID: nil, cdhash: testCDHash)
        let adHoc = "cdhash " + testCDHash.prefix(8)
        let path = "/opt/homebrew/Cellar/python@3.14/3.14.0/bin/python3.14"
        let reply = PendingReply(
            events: [PendingSummary(id: "ev-0000002d", app: python, path: path, host: "sts.amazonaws.com", ip: "203.0.113.7",
                                    port: 443, secondsLeft: 40, connections: 1, script: "/Users/me/My Tools/it's.py"),
                     PendingSummary(id: "ev-0000002e", app: python, path: path, host: "pypi.org", ip: "203.0.113.8",
                                    port: 443, secondsLeft: 40, connections: 1, script: "tool.py")],
            approvals: [ApprovalSummary(app: python, host: "sts.amazonaws.com", secondsLeft: 3599, scope: .script("/opt/homebrew/bin/aws"))],
            denials: [ApprovalSummary(app: python, host: "s3.amazonaws.com", secondsLeft: 540, scope: .script(nil)),
                      ApprovalSummary(app: python, host: "s3.amazonaws.com", secondsLeft: 300, scope: .script("-m boto"))])
        try reply.validate(now: Date())
        #expect(CLI.pendingLines(reply) == [
            "Waiting",
            "  \(adHoc) → sts.amazonaws.com:443  1 connection, 40s left",
            "    \(path)",
            "    running /Users/me/My Tools/it's.py",
            "    blackice approve --cdhash \(testCDHash) --host sts.amazonaws.com --script '/Users/me/My Tools/it'\\''s.py'",
            // A relative script cannot be named: the command approves every script, which only a person can.
            "  \(adHoc) → pypi.org:443  1 connection, 40s left",
            "    \(path)",
            "    running tool.py",
            "    blackice approve --cdhash \(testCDHash) --host pypi.org",
            "",
            "Denied, dropped without asking",
            "  \(adHoc) → s3.amazonaws.com  9m  with no script",
            "    blackice approve --cdhash \(testCDHash) --host s3.amazonaws.com",
            "  \(adHoc) → s3.amazonaws.com  5m  running -m boto",
            "    blackice approve --cdhash \(testCDHash) --host s3.amazonaws.com --script '-m boto'",
            "",
            "Approvals",
            "  \(adHoc) → sts.amazonaws.com  59m  running /opt/homebrew/bin/aws",
        ])
        #expect(CLI.shellQuoted("/opt/homebrew/bin/aws") == "/opt/homebrew/bin/aws" && CLI.shellQuoted("a b") == "'a b'")
        #expect(CLI.shellQuoted("$(x)") == "'$(x)'" && CLI.shellQuoted("~/x") == "'~/x'")
    }

    @Test func durations() {
        #expect(CLI.parseDuration("30s") == 30)
        #expect(CLI.parseDuration("10m") == 600)
        #expect(CLI.parseDuration("24h") == 86_400)
        for bad in ["", "h", "0h", "01h", "1.5h", "-1h", "1d", "1H", "1 h", "1hh", "9999999s"] {
            #expect(CLI.parseDuration(bad) == nil, "\(bad) must be refused")
        }
    }

    @Test func usageErrors() {
        let cases: [([String], String)] = [
            ([], "missing command"),
            (["frobnicate"], "unknown command"),
            (["start", "now"], "unexpected argument 'now'"),
            (["start", "--config"], "--config needs a value"),
            (["start", "--config", "--force"], "--config needs a path"),
            (["start", "--config", "a", "--config", "b"], "given twice"),
            (["start", "--mode", "ask"], "unknown option --mode"),
            (["stop", "now"], "takes no arguments"),
            (["status", "--verbose"], "takes no arguments"),
            (["mode"], "accept-all, ask or block-all"),
            (["mode", "allow-all"], "accept-all, ask or block-all"),
            (["mode", "ask", "extra"], "unexpected argument 'extra'"),
            (["mode", "block-all", "--agent", "fx"], "--agent goes with ask"),
            (["mode", "ask", "--agent", "gemini"], "--agent takes fx, claude-code, codex, opencode, you"),
            (["mode", "ask", "--agent"], "--agent needs a value"),
            (["validate"], "one path"),
            (["validate", "a", "b"], "one path"),
            (["approve", "--host", "example.com"], "needs --app or --cdhash"),
            (["approve", "--cdhash", testCDHash, "--app", "com.a", "--host", "example.com"], "cannot be combined"),
            (["deny", "--cdhash", testCDHash, "--team", "ABCDE12345", "--host", "example.com"], "cannot be combined"),
            (["approve", "--cdhash", "abc", "--host", "example.com"], "40 hex digits"),
            (["approve", "--cdhash", String(repeating: "g", count: 40), "--host", "example.com"], "40 hex digits"),
            (["approve", "--app", "com.a"], "needs --host"),
            (["approve", "--app", "com.a\" or true", "--host", "example.com"], "signing identifier"),
            (["approve", "--app", "com.a", "--team", "abc", "--host", "example.com"], "Team ID"),
            (["approve", "--app", "com.a", "--host", "*.example.com"], "with no wildcards"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "25h"], "at most 24h"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "forever"], "at most 24h"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "1441m"], "at most 24h"),
            (["approve", "--app", "com.a", "--host", "example.com", "--app", "com.b"], "given twice"),
            (["approve", "--app", "com.a", "--host"], "needs a value"),
            (["approve", "--app=", "--host", "example.com"], "needs a value"),
            (["approve", "--app", "com.a", "--host", "example.com", "--yes"], "unknown option --yes"),
            (["approve", "com.a"], "unexpected argument"),
            (["deny", "--app", "com.a", "--host", "example.com", "--for", "1h"], "unknown option --for"),
        ]
        for (arguments, fragment) in cases {
            let message = usageError(arguments)
            #expect(message?.contains(fragment) == true, "\(arguments): \(message ?? "parsed")")
        }
    }

    @Test func echoedArgumentsArePrintable() {
        let message = usageError(["\u{1b}[2J" + String(repeating: "x", count: 100)]) ?? ""
        #expect(!message.unicodeScalars.contains { $0.value < 0x20 })
        #expect(message.contains("…"))
    }
}

struct RunTests {
    @Test func helpAndNoArguments() {
        let help = run(["help"])
        #expect(help.status == 0 && help.stdout.hasPrefix("blackice: an app firewall for macOS") && help.stderr.isEmpty)
        #expect(help.stdout.contains("Usage: blackice COMMAND [options]") && !help.stdout.contains("phase-0"))
        // One screen: the commands, then where their options are.
        #expect(help.stdout.split(separator: "\n").count <= 20)
        for name in ["codex", "opencode", "agent install", "validate"] { #expect(help.stdout.contains(name), "\(name)") }
        let none = run([])
        #expect(none.status == ExitCode.usage && none.stderr.hasPrefix("blackice: an app firewall") && none.stdout.isEmpty)
        // Each command's own help starts with its usage line.
        let mode = run(["help", "mode"])
        #expect(mode.status == 0 && mode.stdout.hasPrefix("Usage: blackice mode accept-all|ask|block-all [--agent NAME]"))
        #expect(mode.stdout.contains("codex, opencode or you"))
        #expect(run(["approve", "--help"]).stdout.hasPrefix("Usage: blackice approve --app ID"))
        for name in CLI.commandHelp.keys { #expect(CLI.commandHelp[name]?.first?.hasPrefix("Usage: blackice \(name)") == true, "\(name)") }
        // Every line fits an 80-column Terminal window.
        for line in CLI.usage.split(separator: "\n").map(String.init) + CLI.commandHelp.values.flatMap({ $0 }) { #expect(line.count <= 80, "\(line)") }
    }

    @Test func usageErrorExitsWith64() {
        let result = run(["mode", "sometimes"])
        #expect(result.status == 64)
        #expect(result.stderr == "blackice: mode takes accept-all, ask or block-all\nUsage: blackice mode accept-all|ask|block-all [--agent NAME]")
        #expect(run(["sometimes"]).stderr == "blackice: unknown command 'sometimes'\nRun: blackice help")
        #expect(result.stdout.isEmpty)
    }

    @Test func validateReportsAValidFile() {
        let result = run(["validate", "n.toml"], files: ["n.toml": Data("mode = 'ask'\n".utf8)])
        #expect(result.status == 0)
        #expect(result.stdout == "✓ n.toml is valid: ask mode, no rules, no hooks, 10 s to answer")
        #expect(result.stderr.isEmpty)
    }

    @Test func validateReportsTheLine() {
        let result = run(["validate", "n.toml"], files: ["n.toml": Data("mode = 'ask'\nmode = 'ask'\n".utf8)])
        #expect(result.status == 65)
        #expect(result.stderr == "n.toml:2: duplicate key 'mode' at the top level (first set on line 1)")
        #expect(result.stdout.isEmpty)
        let empty = run(["validate", "e.toml"], files: ["e.toml": Data()])
        #expect(empty.status == 65 && empty.stderr == "e.toml: the file is empty")
    }

    @Test func validateMissingFile() {
        let result = run(["validate", "missing.toml"])
        #expect(result.status == 66 && result.stderr == "missing.toml: there is no such file")
    }

    @Test func commandsThatNeedTheSignedAppSaySoAndFail() {
        for arguments in [["stop"], ["status"], ["mode", "ask"]] {
            let result = run(arguments)
            #expect(result.status == 69 && result.stdout.isEmpty)
            #expect(result.stderr == UnsignedSystem.refusal(arguments[0]))
            #expect(result.stderr.contains("/Applications/Blackice.app/Contents/MacOS/blackice") && !result.stderr.contains("docs/"))
        }
        // start checks its configuration first, so a bad file is reported even here.
        let start = run(["start", "--config", "n.toml"], files: ["n.toml": Data("mode = \"block-all\"\n".utf8)])
        #expect(start.status == 69)
        #expect(start.stdout.isEmpty)
        #expect(start.stderr == UnsignedSystem.refusal("start"))
    }

    @Test func startReadsTheFileOnceAndPassesItsText() {
        let text = "mode = \"accept-all\"\n\n[[allow]]\napp = \"com.apple.curl\"\nhosts = [\"pypi.org\"]\n"
        let system = FakeSystem()
        let result = run(["start", "--config", "n.toml"], files: ["n.toml": Data(text.utf8)], system: system)
        #expect(result.status == 0)
        #expect(result.stdout == "started")
        #expect(system.calls == ["start " + text])

        let defaultPath = FakeSystem()
        let fallback = run(["start"], files: [CLI.defaultConfigPath: Data("mode = \"ask\"\n".utf8)], system: defaultPath)
        #expect(fallback.status == 0 && defaultPath.calls == ["start mode = \"ask\"\n"])
        #expect(CLI.defaultConfigPath.hasSuffix("/.config/blackice/blackice.toml"))

        // A missing or bad file never reaches the system.
        let untouched = FakeSystem()
        #expect(run(["start", "--config", "missing.toml"], system: untouched).status == 66)
        #expect(run(["start", "--config", "b.toml"], files: ["b.toml": Data("mode = 'x'\n".utf8)], system: untouched).status == 65)
        let missing = run(["start"], system: untouched)
        #expect(missing.status == 66)
        #expect(missing.stderr == "There is no configuration at ~/.config/blackice/blackice.toml yet. Write one with: blackice init")
        let bad = run(["start", "--config", "b.toml"], files: ["b.toml": Data("mode = 'x'\n".utf8)], system: untouched)
        #expect(bad.stderr.hasSuffix("Fix the file, then check it with: blackice validate b.toml"))
        #expect(untouched.calls.isEmpty)
    }

    @Test func systemCommandsPassThroughTheirStatus() {
        let system = FakeSystem(status: ExitCode.noPermission)
        let stop = run(["stop"], system: system)
        let status = run(["status"], system: system)
        let mode = run(["mode", "block-all"], system: system)
        let agent = run(["mode", "ask", "--agent", "codex"], system: system)
        #expect(system.calls == ["stop", "status", "mode block-all", "mode ask --agent codex"] && agent.status == 77)
        #expect(stop.status == 77 && status.status == 77 && mode.status == 77)
        #expect(status.stdout == "filter: enabled" && mode.stderr == "mode refused")
    }

    @Test func askCommandsReachTheSystem() {
        let system = FakeSystem(status: ExitCode.noPermission)
        #expect(run(["pending"], system: system).status == 77)
        #expect(run(["approve", "--app", "com.a", "--host", "Example.com", "--for", "5m"], system: system).status == 77)
        #expect(run(["deny", "--cdhash", testCDHash, "--host", "example.com"], system: system).status == 77)
        #expect(system.calls == ["pending", "approve apple/com.a example.com 300 touch_id",
                                 "deny cdhash/\(testCDHash) example.com - touch_id"])
        // A usage error never reaches it.
        #expect(run(["approve", "--app", "com.a", "--host", "example.com", "--for", "2d"], system: system).status == 64)
        #expect(system.calls.count == 3)
    }

    @Test func severalHostsReachTheSystemAsOneAnswerEach() {
        let system = FakeSystem()
        let arguments = ["approve", "--app", "com.a", "--host", "a.example.com", "--host", "b.example.com", "--for", "5m"]
        #expect(run(arguments, system: system).status == 0)
        #expect(system.calls == ["approve apple/com.a a.example.com 300 touch_id", "approve apple/com.a b.example.com 300 touch_id"])
        // Without NESystemControl's single Touch ID, the first answer that does not go through stops the rest.
        let refusing = FakeSystem(status: ExitCode.noPermission)
        #expect(run(arguments, system: refusing).status == 77)
        #expect(refusing.calls == ["approve apple/com.a a.example.com 300 touch_id"])
    }

    /// `approve --save` adds a rule for the hosts no rule covers yet, after the approval went through.
    @Test func saveAddsALastingRuleAfterTheApproval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-save-\(getpid())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("blackice.toml").path
        let text = "mode = \"ask\"\n\n[[allow]]\ncdhash = \"\(testCDHash)\"\nhosts = [\"api.github.com\"]\n"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        let arguments = ["approve", "--cdhash", testCDHash, "--host", "api.github.com", "--host", "uploads.github.com",
                         "--for", "1h", "--save", "--config", path]
        let system = FakeSystem()
        let saved = run(arguments, files: [path: Data(text.utf8)], system: system)
        #expect(saved.status == 0)
        #expect(system.calls.count == 2)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.hasPrefix(text))
        #expect(written.hasSuffix("[[allow]]\ncdhash = \"\(testCDHash)\"\nhosts = [\"uploads.github.com\"]\n"))
        #expect(try BlackiceConfig(text: written).allowRule(for: .cdhash(testCDHash), host: "uploads.github.com") != nil)
        #expect(saved.stdout.contains("never counts"))
        // A refused approval saves nothing, and neither does one whose hosts are all covered.
        let refused = run(arguments, files: [path: Data(written.utf8)], system: FakeSystem(status: ExitCode.noPermission))
        #expect(refused.status == 77)
        let again = run(arguments, files: [path: Data(written.utf8)], system: FakeSystem())
        #expect(again.status == 0 && again.stdout.contains("already has a rule"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == written)
        // --config only with --save.
        #expect(usageError(["approve", "--cdhash", testCDHash, "--host", "a.example.com", "--config", path])?
            .contains("--config goes with --save") == true)
    }

    @Test func askCommandsNeedTheSignedApp() {
        let commands: [[String]] = [["pending"], ["approve", "--app", "com.a", "--host", "example.com"],
                                    ["approve", "--app", "com.a", "--host", "a.example.com", "--host", "b.example.com"],
                                    ["deny", "--cdhash", testCDHash, "--host", "example.com"]]
        for arguments in commands {
            let result = run(arguments)
            #expect(result.status == 69 && result.stdout.isEmpty)
            #expect(result.stderr == UnsignedSystem.refusal(arguments[0]))
        }
    }

    @Test func pendingLinesNeverShowATokenAndStayPrintable() {
        let tool = AppReference(signingID: "com.example.tool", teamID: "ABCDE12345", cdhash: nil)
        let reply = PendingReply(
            events: [PendingSummary(id: "ev-0000002a", app: tool, path: "/usr/local/bin/tool", host: "example.com",
                                    ip: "203.0.113.7", port: 443, secondsLeft: 8, connections: 3),
                     PendingSummary(id: "ev-0000002b", app: AppReference(signingID: nil, teamID: nil, cdhash: testCDHash),
                                    path: nil, host: "pypi.org", ip: "2001:db8::1", port: 80, secondsLeft: 2, connections: 1)],
            approvals: [ApprovalSummary(app: tool, host: "api.example.com", secondsLeft: 3599)])
        let adHoc = "cdhash " + testCDHash.prefix(8)
        #expect(CLI.pendingLines(reply) == [
            "Waiting",
            "  com.example.tool (ABCDE12345) → example.com:443  3 connections, 8s left",
            "    blackice approve --app com.example.tool --team ABCDE12345 --host example.com",
            "  \(adHoc) → pypi.org:80  1 connection, 2s left",
            "    blackice approve --cdhash \(testCDHash) --host pypi.org",
            "",
            "Approvals",
            "  com.example.tool (ABCDE12345) → api.example.com  59m",
        ])
        #expect(CLI.pendingLines(PendingReply(events: [], approvals: [])) == ["Nothing waiting, and no approvals."])

        // A connection with no name, asked about by its address.
        let ssh = AppReference(signingID: "com.apple.ssh", teamID: nil, cdhash: nil)
        let byAddress = PendingReply(
            events: [PendingSummary(id: "ev-0000002c", app: ssh, path: nil, host: "100.66.32.75", ip: "100.66.32.75",
                                    port: 22, secondsLeft: 50, connections: 1),
                     PendingSummary(id: "ev-0000002d", app: ssh, path: nil, host: "fd7a:115c:a1e0::1",
                                    ip: "fd7a:115c:a1e0::1", port: 22, secondsLeft: 40, connections: 1)],
            approvals: [ApprovalSummary(app: ssh, host: "100.66.32.76", secondsLeft: 60)])
        #expect(CLI.pendingLines(byAddress) == [
            "Waiting",
            "  com.apple.ssh → 100.66.32.75:22  1 connection, 50s left",
            "    blackice approve --app com.apple.ssh --host 100.66.32.75",
            "  com.apple.ssh → [fd7a:115c:a1e0::1]:22  1 connection, 40s left",
            "    blackice approve --app com.apple.ssh --host fd7a:115c:a1e0::1",
            "",
            "Approvals",
            "  com.apple.ssh → 100.66.32.76  1m",
        ])

        // Denials remembered for a while, listed only when there are some, in columns.
        let denied = PendingReply(events: [], approvals: [],
                                  denials: [ApprovalSummary(app: AppReference(signingID: nil, teamID: nil, cdhash: testCDHash),
                                                            host: "registry.example.com", secondsLeft: 540),
                                            ApprovalSummary(app: ssh, host: "100.66.32.75", secondsLeft: 12)])
        #expect(CLI.pendingLines(denied) == [
            "Denied, dropped without asking",
            "  \(adHoc) → registry.example.com  9m",
            "    blackice approve --cdhash \(testCDHash) --host registry.example.com",
            "  com.apple.ssh   → 100.66.32.75          12s",
            "    blackice approve --app com.apple.ssh --host 100.66.32.75",
        ])

        // Ad hoc code is known by its path, which is wherever it runs from and may hold an escape sequence.
        let odd = PendingReply(events: [PendingSummary(id: "ev-0000002a", app: AppReference(signingID: nil, teamID: nil, cdhash: testCDHash),
                                                       path: "/tmp/x\u{9B}2J\u{202E}y", host: "example.com", ip: "203.0.113.7",
                                                       port: 443, secondsLeft: 8, connections: 1)], approvals: [])
        #expect(CLI.pendingLines(odd)[2] == "    /tmp/x\\u{9b}2J\\u{202e}y")
    }

    /// A remembered denial drops the app's connections with no event, so "Nothing waiting" led a
    /// person to think there was nothing to approve while a CLI kept failing (6 November 2026).
    /// The denials come first, each app's hosts together with one command that approves them all.
    @Test func pendingPutsDenialsFirstWithOneCommandPerApp() {
        let python = AppReference(signingID: nil, teamID: nil, cdhash: testCDHash)
        let ssh = AppReference(signingID: "com.apple.ssh", teamID: nil, cdhash: nil)
        let adHoc = "cdhash " + testCDHash.prefix(8)
        let reply = PendingReply(
            events: [], approvals: [ApprovalSummary(app: ssh, host: "100.66.32.76", secondsLeft: 3599)],
            denials: [ApprovalSummary(app: python, host: "oauth2.googleapis.com", secondsLeft: 540),
                      ApprovalSummary(app: ssh, host: "100.66.32.75", secondsLeft: 300),
                      ApprovalSummary(app: python, host: "login.microsoftonline.com", secondsLeft: 600)])
        #expect(CLI.pendingLines(reply) == [
            "Denied, dropped without asking",
            "  \(adHoc) → oauth2.googleapis.com      9m",
            "  \(adHoc) → login.microsoftonline.com  10m",
            "    blackice approve --cdhash \(testCDHash) --host oauth2.googleapis.com --host login.microsoftonline.com",
            "  com.apple.ssh   → 100.66.32.75               5m",
            "    blackice approve --app com.apple.ssh --host 100.66.32.75",
            "",
            "Approvals",
            "  com.apple.ssh → 100.66.32.76  59m",
        ])

        // With something waiting too, the waiting events come first.
        let tool = AppReference(signingID: "com.apple.curl", teamID: nil, cdhash: nil)
        let both = PendingReply(
            events: [PendingSummary(id: "ev-0000002a", app: tool, path: nil, host: "example.com", ip: "203.0.113.7",
                                    port: 443, secondsLeft: 8, connections: 1)],
            approvals: [], denials: [ApprovalSummary(app: ssh, host: "100.66.32.75", secondsLeft: 300)])
        #expect(CLI.pendingLines(both) == [
            "Waiting",
            "  com.apple.curl → example.com:443  1 connection, 8s left",
            "    blackice approve --app com.apple.curl --host example.com",
            "",
            "Denied, dropped without asking",
            "  com.apple.ssh → 100.66.32.75  5m",
            "    blackice approve --app com.apple.ssh --host 100.66.32.75",
        ])

        // More hosts than one approve takes: one command per 16, and each parses.
        let many = PendingReply(events: [], approvals: [],
                                denials: (1...17).map { ApprovalSummary(app: python, host: "h\($0).example.com", secondsLeft: 60) })
        let commands = CLI.pendingLines(many).filter { $0.hasPrefix("    blackice approve") }
        #expect(commands.count == 2)
        let parsed = commands.compactMap { line -> Approval? in
            guard case .approve(let approval)? = try? CLI.parse(Array(line.split(separator: " ").dropFirst().map(String.init))) else {
                return nil
            }
            return approval
        }
        #expect(parsed.map(\.hosts.count) == [16, 1])
    }

    @Test func anEventWithNoConnectionLeftIsValidAndSaysSo() throws {
        // Its flows were dropped with hold_expired; the event stays until its deadline (Mac run, 3 November 2026).
        let tool = AppReference(signingID: "com.apple.curl", teamID: nil, cdhash: nil)
        let reply = PendingReply(
            events: [PendingSummary(id: "ev-0000002c", app: tool, path: "/usr/bin/curl", host: "api.github.com",
                                    ip: "203.0.113.7", port: 443, secondsLeft: 40, connections: 0)],
            approvals: [])
        try reply.validate(now: Date())
        #expect(CLI.pendingLines(reply) == [
            "Waiting",
            "  com.apple.curl → api.github.com:443  none held, 40s left",
            "    blackice approve --app com.apple.curl --host api.github.com",
        ])
    }

    @Test func timeLeftReadsAsHoursAndMinutes() {
        #expect([0, 45, 60, 3599, 3600, 86155, 86400].map(Describe.left) == ["0s", "45s", "1m", "59m", "1h", "23h 55m", "24h"])
    }

    @Test func answerExitStatus() {
        #expect(CLI.answerStatus(AnswerReply(status: .done, reason: "approved", message: "ok")) == 0)
        #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: "invalid_request", message: "x")) == 64)
        #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: "unavailable", message: "x")) == 69)
        for reason in ["token_unknown", "token_spent", "token_expired", "token_mismatch", "not_the_daemon", "touch_id_failed"] {
            #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: reason, message: "x")) == 77)
        }
    }

    @Test func theDaemonTakesNoConfigFile() throws {
        #expect(try CLI.parse(["daemon"]) == .daemon)
        let removed = "daemon takes no --config: it runs the hooks of what blackice start loaded"
        for arguments in [["daemon", "--config", "attacker.toml"], ["daemon", "--config=attacker.toml"], ["daemon", "--config"],
                          ["daemon", "--log", "x", "--config", "attacker.toml"]] {
            #expect(usageError(arguments) == removed, "\(arguments)")
        }
        #expect(usageError(["daemon", "--log", "x"]) == "daemon takes no arguments")
        #expect(usageError(["daemon", "now"]) == "daemon takes no arguments")

        // The file is never read, even when it exists, and nothing reaches the system.
        let system = FakeSystem()
        let refused = run(["daemon", "--config", "n.toml"], files: ["n.toml": Data("mode = \"ask\"\n".utf8)], system: system)
        #expect(refused.status == 64 && refused.stdout.isEmpty && refused.stderr.contains(removed))
        #expect(system.calls.isEmpty)

        #expect(run(["daemon"], system: system).status == 0 && system.calls == ["daemon"])
        let unsigned = run(["daemon"])
        #expect(unsigned.status == 69 && unsigned.stdout.isEmpty && unsigned.stderr == UnsignedSystem.refusal("daemon"))
    }

    @Test func agentInstallAndUninstall() throws {
        #expect(try CLI.parse(["agent", "install"]) == .agent(.install))
        #expect(try CLI.parse(["agent", "uninstall"]) == .agent(.uninstall))
        for arguments in [["agent"], ["agent", "load"], ["agent", "install", "--force"], ["agent", "--install"]] {
            #expect(usageError(arguments) == "agent takes install, uninstall or connect", "\(arguments)")
        }
        let system = FakeSystem(status: ExitCode.software)
        #expect(run(["agent", "install"], system: system).status == 70)
        #expect(run(["agent", "uninstall"], system: system).status == 70)
        #expect(system.calls == ["agent install", "agent uninstall"])
        #expect(CLI.usage.contains("agent install|uninstall"))
        #expect(!CLI.usage.contains("daemon --config"))
    }

    @Test func realFilesThroughReadConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/blackice.toml")
        #expect(try BlackiceConfig(data: CLI.readConfigFile(example.path)).mode == .ask)

        // A file far over the limit is cut at limit + 1 bytes and refused for its size.
        let huge = directory.appendingPathComponent("huge.toml")
        try Data(repeating: 0x23, count: BlackiceConfig.maximumBytes * 4).write(to: huge)
        let read = try CLI.readConfigFile(huge.path)
        #expect(read.count == BlackiceConfig.maximumBytes + 1)
        #expect(throws: ConfigError(line: nil, "the file is larger than 64 KiB")) { try BlackiceConfig(data: read) }
    }
}
