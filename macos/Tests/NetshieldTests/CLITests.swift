import Foundation
import Testing
@testable import NetshieldCLI
@testable import NetshieldCore

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

    func pending(output: SystemOutput) -> Int32 { calls.append("pending"); return answer }

    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 {
        calls.append("\(request.kind.rawValue) \(request.app.identity?.label ?? "?") \(request.host) " +
                     "\(request.seconds.map(String.init) ?? "-") \(request.authorization.rawValue)")
        return answer
    }

    func runDaemon(config: NetshieldConfig, output: SystemOutput) -> Int32 {
        calls.append("daemon " + config.summary)
        return answer
    }
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
        #expect(try CLI.parse(["--help"]) == .help)
        #expect(try CLI.parse(["validate", "netshield.toml"]) == .validate(path: "netshield.toml"))
        for mode in Mode.allCases { #expect(try CLI.parse(["mode", mode.rawValue]) == .mode(mode)) }
    }

    @Test func approveDefaultsAndForms() throws {
        let approval = try CLI.parse(["approve", "--app", "com.example.tool", "--team=ABCDE12345",
                                      "--host", "Example.COM.", "--token", "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys"])
        let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
        #expect(approval == .approve(Approval(identity: tool, host: "example.com",
                                              seconds: 3600, token: "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys")))
        let apple = try CLI.parse(["approve", "--app", "com.apple.curl", "--host", "example.com", "--for", "10m"])
        let curl = AppIdentity.signed(SigningIdentity(signingID: "com.apple.curl", teamID: nil))
        #expect(apple == .approve(Approval(identity: curl, host: "example.com", seconds: 600, token: nil)))
        let denial = try CLI.parse(["deny", "--host", "example.com", "--app", "com.example.tool"])
        let untrusted = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: nil))
        #expect(denial == .deny(Denial(identity: untrusted, host: "example.com", token: nil)))
    }

    @Test func cdhashNamesAdHocCode() throws {
        let upper = testCDHash.uppercased()
        let approval = try CLI.parse(["approve", "--cdhash", upper, "--host", "example.com", "--for", "30s"])
        #expect(approval == .approve(Approval(identity: .cdhash(testCDHash), host: "example.com", seconds: 30, token: nil)))
        let denial = try CLI.parse(["deny", "--cdhash=\(testCDHash)", "--host", "example.com"])
        #expect(denial == .deny(Denial(identity: .cdhash(testCDHash), host: "example.com", token: nil)))
        if case .approve(let parsed) = approval {
            #expect(parsed.request.app == AppReference(signingID: nil, teamID: nil, cdhash: testCDHash))
            #expect(parsed.request.authorization == .touchID)
            #expect(throws: Never.self) { try parsed.request.validate(now: Date()) }
        }
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
            (["mode", "ask", "extra"], "accept-all, ask or block-all"),
            (["validate"], "one path"),
            (["validate", "a", "b"], "one path"),
            (["validate", "--help"], "one path"),
            (["approve", "--host", "example.com"], "needs --app or --cdhash"),
            (["approve", "--cdhash", testCDHash, "--app", "com.a", "--host", "example.com"], "cannot be combined"),
            (["deny", "--cdhash", testCDHash, "--team", "ABCDE12345", "--host", "example.com"], "cannot be combined"),
            (["approve", "--cdhash", "abc", "--host", "example.com"], "40 hex digits"),
            (["approve", "--cdhash", String(repeating: "g", count: 40), "--host", "example.com"], "40 hex digits"),
            (["approve", "--app", "com.a", "--host", "example.com", "--token", "short"], "token from the event"),
            (["approve", "--app", "com.a"], "needs --host"),
            (["approve", "--app", "com.a\" or true", "--host", "example.com"], "signing identifier"),
            (["approve", "--app", "com.a", "--team", "abc", "--host", "example.com"], "Team ID"),
            (["approve", "--app", "com.a", "--host", "*.example.com"], "wildcards and IP addresses"),
            (["approve", "--app", "com.a", "--host", "203.0.113.7"], "wildcards and IP addresses"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "25h"], "at most 24h"),
            (["approve", "--app", "com.a", "--host", "example.com", "--for", "forever"], "at most 24h"),
            (["approve", "--app", "com.a", "--host", "example.com", "--token", "a b"], "token from the event"),
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
        #expect(help.status == 0 && help.stdout.hasPrefix("usage: netshield") && help.stderr.isEmpty)
        let none = run([])
        #expect(none.status == ExitCode.usage && none.stderr.hasPrefix("usage: netshield") && none.stdout.isEmpty)
    }

    @Test func usageErrorExitsWith64() {
        let result = run(["mode", "sometimes"])
        #expect(result.status == 64)
        #expect(result.stderr.contains("netshield: mode takes one of accept-all, ask or block-all"))
        #expect(result.stdout.isEmpty)
    }

    @Test func validateReportsAValidFile() {
        let result = run(["validate", "n.toml"], files: ["n.toml": Data("mode = 'ask'\n".utf8)])
        #expect(result.status == 0)
        #expect(result.stdout == "n.toml: valid (mode ask, timeout 10 s, 0 allow rules, 0 hooks)")
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
        #expect(result.status == 66 && result.stderr.hasPrefix("missing.toml: cannot read the file"))
    }

    @Test func commandsThatNeedTheSignedAppSaySoAndFail() {
        for arguments in [["stop"], ["status"], ["mode", "ask"]] {
            let result = run(arguments)
            #expect(result.status == 69 && result.stdout.isEmpty)
            #expect(result.stderr == UnsignedSystem.refusal(arguments[0]))
            #expect(result.stderr.hasSuffix("(see docs/phase-0.md)"))
        }
        // start checks its configuration first, so a bad file is reported even here.
        let start = run(["start", "--config", "n.toml"], files: ["n.toml": Data("mode = \"block-all\"\n".utf8)])
        #expect(start.status == 69)
        #expect(start.stdout == "n.toml: valid (mode block-all, timeout 10 s, 0 allow rules, 0 hooks)")
        #expect(start.stderr == UnsignedSystem.refusal("start"))
    }

    @Test func startReadsTheFileOnceAndPassesItsText() {
        let text = "mode = \"accept-all\"\n\n[[allow]]\napp = \"com.apple.curl\"\nhosts = [\"pypi.org\"]\n"
        let system = FakeSystem()
        let result = run(["start", "--config", "n.toml"], files: ["n.toml": Data(text.utf8)], system: system)
        #expect(result.status == 0)
        #expect(result.stdout == "n.toml: valid (mode accept-all, timeout 10 s, 1 allow rule, 0 hooks)\nstarted")
        #expect(system.calls == ["start " + text])

        let defaultPath = FakeSystem()
        let fallback = run(["start"], files: [CLI.defaultConfigPath: Data("mode = \"ask\"\n".utf8)], system: defaultPath)
        #expect(fallback.status == 0 && defaultPath.calls == ["start mode = \"ask\"\n"])
        #expect(CLI.defaultConfigPath.hasSuffix("/.config/netshield/netshield.toml"))

        // A missing or bad file never reaches the system.
        let untouched = FakeSystem()
        #expect(run(["start", "--config", "missing.toml"], system: untouched).status == 66)
        #expect(run(["start", "--config", "b.toml"], files: ["b.toml": Data("mode = 'x'\n".utf8)], system: untouched).status == 65)
        #expect(run(["start"], system: untouched).status == 66)
        #expect(untouched.calls.isEmpty)
    }

    @Test func systemCommandsPassThroughTheirStatus() {
        let system = FakeSystem(status: ExitCode.noPermission)
        let stop = run(["stop"], system: system)
        let status = run(["status"], system: system)
        let mode = run(["mode", "block-all"], system: system)
        #expect(system.calls == ["stop", "status", "mode block-all"])
        #expect(stop.status == 77 && status.status == 77 && mode.status == 77)
        #expect(status.stdout == "filter: enabled" && mode.stderr == "mode refused")
    }

    @Test func askCommandsReachTheSystem() {
        let token = "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys"
        let system = FakeSystem(status: ExitCode.noPermission)
        #expect(run(["pending"], system: system).status == 77)
        #expect(run(["approve", "--app", "com.a", "--host", "Example.com", "--for", "5m", "--token", token],
                    system: system).status == 77)
        #expect(run(["deny", "--cdhash", testCDHash, "--host", "example.com"], system: system).status == 77)
        #expect(system.calls == ["pending", "approve apple/com.a example.com 300 token",
                                 "deny cdhash/\(testCDHash) example.com - touch_id"])
        // A usage error never reaches it.
        #expect(run(["approve", "--app", "com.a", "--host", "example.com", "--for", "2d"], system: system).status == 64)
        #expect(system.calls.count == 3)
    }

    @Test func askCommandsNeedTheSignedApp() {
        let commands: [[String]] = [["pending"], ["approve", "--app", "com.a", "--host", "example.com"],
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
        #expect(CLI.pendingLines(reply) == [
            "Waiting:",
            "  ev-0000002a  ABCDE12345/com.example.tool -> example.com:443 (203.0.113.7), 3 connections, 8 s left",
            "      /usr/local/bin/tool",
            "  ev-0000002b  cdhash/\(testCDHash) -> pypi.org:80 (2001:db8::1), 1 connection, 2 s left",
            "Approvals:",
            "  ABCDE12345/com.example.tool -> api.example.com, 3599 s left",
        ])
        #expect(CLI.pendingLines(PendingReply(events: [], approvals: [])) == ["No connection is waiting.", "No approvals."])
    }

    @Test func answerExitStatus() {
        #expect(CLI.answerStatus(AnswerReply(status: .done, reason: "approved", message: "ok")) == 0)
        #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: "invalid_request", message: "x")) == 64)
        #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: "unavailable", message: "x")) == 69)
        for reason in ["token_unknown", "token_spent", "token_expired", "token_mismatch", "touch_id_failed"] {
            #expect(CLI.answerStatus(AnswerReply(status: .refused, reason: reason, message: "x")) == 77)
        }
    }

    @Test func daemonChecksItsConfigurationThenNeedsTheSignedApp() throws {
        #expect(usageError(["daemon"]) == "daemon needs --config PATH")
        #expect(usageError(["daemon", "--config"]) == "daemon: --config needs a value")
        #expect(usageError(["daemon", "--config", "a", "--log", "b"]) == "daemon: unknown option --log")
        #expect(try CLI.parse(["daemon", "--config=/etc/netshield.toml"]) == .daemon(configPath: "/etc/netshield.toml"))

        let good = run(["daemon", "--config", "n.toml"], files: ["n.toml": Data("mode = \"ask\"\n".utf8)])
        #expect(good.status == 69)
        #expect(good.stdout == "n.toml: valid (mode ask, timeout 10 s, 0 allow rules, 0 hooks)")
        #expect(good.stderr == UnsignedSystem.refusal("daemon"))

        let system = FakeSystem()
        let real = run(["daemon", "--config", "n.toml"], files: ["n.toml": Data("mode = \"ask\"\n".utf8)], system: system)
        #expect(real.status == 0 && system.calls == ["daemon mode ask, timeout 10 s, 0 allow rules, 0 hooks"])

        let bad = run(["daemon", "--config", "n.toml"], files: ["n.toml": Data("mode = \"loud\"\n".utf8)])
        #expect(bad.status == 65 && bad.stderr.hasPrefix("n.toml:1: mode must be"))
        #expect(run(["daemon", "--config", "missing.toml"]).status == 66)
    }

    @Test func realFilesThroughReadConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netshield-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/netshield.toml")
        #expect(try NetshieldConfig(data: CLI.readConfigFile(example.path)).mode == .ask)

        // A file far over the limit is cut at limit + 1 bytes and refused for its size.
        let huge = directory.appendingPathComponent("huge.toml")
        try Data(repeating: 0x23, count: NetshieldConfig.maximumBytes * 4).write(to: huge)
        let read = try CLI.readConfigFile(huge.path)
        #expect(read.count == NetshieldConfig.maximumBytes + 1)
        #expect(throws: ConfigError(line: nil, "the file is larger than 64 KiB")) { try NetshieldConfig(data: read) }
    }
}
