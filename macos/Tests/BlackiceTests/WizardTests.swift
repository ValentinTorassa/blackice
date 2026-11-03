import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

/// A terminal that answers from a script and records everything printed; files live in memory.
private final class FakeTerminal: @unchecked Sendable {
    var answers: [String]
    var prompts: [String] = []
    var files: [String: Data]
    let paths: Set<String>
    let identities: [String: SigningIdentity]

    init(_ answers: [String], files: [String: Data] = [:], paths: Set<String> = [],
         identities: [String: SigningIdentity] = [:]) {
        self.answers = answers
        self.files = files
        self.paths = paths
        self.identities = identities
    }

    var interaction: Interaction {
        Interaction(
            ask: { prompt in
                self.prompts.append(prompt)
                return self.answers.isEmpty ? nil : self.answers.removeFirst()
            },
            createFile: { path, data in
                guard self.files[path] == nil else { throw CocoaError(.fileWriteFileExists) }
                self.files[path] = data
            },
            identify: { self.identities[$0] },
            fileExists: { self.files[$0] != nil || self.paths.contains($0) },
            home: NSHomeDirectory(),
            version: "0.2.0 (build 6)")
    }

    func readFile(_ path: String) throws -> Data {
        guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
}

private struct Outcome {
    let status: Int32
    let stdout: [String]
    let stderr: [String]
}

private final class Started: SystemControlling {
    var texts: [String] = []
    func start(configText: String, output: SystemOutput) -> Int32 { texts.append(configText); return 0 }
    func stop(output: SystemOutput) -> Int32 { 0 }
    func status(output: SystemOutput) -> Int32 { 0 }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { 0 }
    func pending(output: SystemOutput) -> Int32 { 0 }
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { 0 }
    func runDaemon(output: SystemOutput) -> Int32 { 0 }
    func installAgent(output: SystemOutput) -> Int32 { 0 }
    func uninstallAgent(output: SystemOutput) -> Int32 { 0 }
}

private func run(_ arguments: [String], _ terminal: FakeTerminal, system: SystemControlling = Started()) -> Outcome {
    let out = Recorder<String>(), err = Recorder<String>()
    let status = CLI.run(arguments, stdout: { out.append($0) }, stderr: { err.append($0) },
                         readFile: terminal.readFile, system: system, interaction: terminal.interaction)
    return Outcome(status: status, stdout: out.items, stderr: err.items)
}

private func answers(_ script: [String], paths: Set<String> = [], identities: [String: SigningIdentity] = [:]) -> ConfigWizard.Answers? {
    let lines = Recorder<String>()
    let terminal = FakeTerminal(script, paths: paths, identities: identities)
    return ConfigWizard(ask: terminal.interaction.ask!, say: lines.append, identify: { identities[$0] },
                        fileExists: { paths.contains($0) }, home: "/Users/test").run()
}

struct WizardTests {
    static let curl = SigningIdentity(signingID: "com.apple.curl", teamID: nil)
    static let slack = SigningIdentity(signingID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL")

    @Test func enterTakesTheDefaults() throws {
        let result = try #require(answers([""]))
        #expect(result == ConfigWizard.Answers(mode: .acceptAll, timeoutSeconds: 60, rules: []))
        let text = ConfigWizard.render(result)
        let config = try BlackiceConfig(data: Data(text.utf8))
        #expect(config.mode == .acceptAll && config.timeoutSeconds == 60 && config.allow.isEmpty)
        #expect(text.hasPrefix("# blackice configuration, written by blackice init.\n"))
        #expect(text.contains("mode = \"accept-all\"     # accept-all, ask or block-all\n"))
        #expect(text.contains("timeout_seconds = 60    # in ask mode, no answer in time means deny\n"))
        #expect(text.contains("# [[allow]]\n"))
    }

    @Test func askModeWithRulesByPathByNameAndByIdentifier() throws {
        let result = try #require(answers(
            ["2", "45",
             "/usr/bin/curl", "pypi.org, files.pythonhosted.org pypi.org",
             "Slack", "*",
             "com.example.agent", "ABCDE12345", "API.Example.com",
             ""],
            paths: ["/usr/bin/curl", "/Applications/Slack.app"],
            identities: ["/usr/bin/curl": Self.curl, "/Applications/Slack.app": Self.slack]))
        #expect(result.mode == .ask && result.timeoutSeconds == 45)
        #expect(result.rules == [
            .init(identity: Self.curl, hosts: ["pypi.org", "files.pythonhosted.org"]),
            .init(identity: Self.slack, hosts: ["*"]),
            .init(identity: SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345"), hosts: ["api.example.com"]),
        ])
        let config = try BlackiceConfig(data: Data(ConfigWizard.render(result).utf8))
        #expect(config.mode == .ask && config.timeoutSeconds == 45 && config.allow.count == 3)
        #expect(config.allowRule(for: Self.curl, host: "files.pythonhosted.org") != nil)
        #expect(config.anyHostRule(for: Self.slack) != nil)
        #expect(config.allowRule(for: Self.curl, host: "example.com") == nil)
    }

    @Test func wrongAnswersAreAskedAgain() throws {
        let result = try #require(answers(
            ["9", "block-all",
             "/tmp/nothing",                       // no such file
             "/tmp/adhoc",                         // unsigned or ad hoc: no identity
             "not an id!",                         // neither
             "Nope",                               // a bare word with no app of that name
             "com.apple.curl", "abc", "",           // a bad Team ID, then Apple's own
             "https://pypi.org", "* pypi.org", "pypi.org",
             "com.example.skip", "", "",            // no hosts: skipped
             ""],
            paths: ["/tmp/adhoc"]))
        #expect(result.mode == .blockAll)
        #expect(result.rules == [.init(identity: Self.curl, hosts: ["pypi.org"])])

        let seconds = try #require(answers(["2", "0", "121", "x", "", ""]))
        #expect(seconds.timeoutSeconds == 60)
    }

    @Test func theEndOfInputWritesNothing() {
        #expect(answers([]) == nil)
        #expect(answers(["2"]) == nil)
        #expect(answers(["3", "/usr/bin/curl"], paths: ["/usr/bin/curl"], identities: ["/usr/bin/curl": Self.curl]) == nil)
    }

    @Test func startWithoutAFileAsksThenStartsWithWhatItWrote() throws {
        let terminal = FakeTerminal([""])
        let system = Started()
        let result = run(["start"], terminal, system: system)
        #expect(result.status == 0)
        let written = try #require(terminal.files[CLI.defaultConfigPath])
        #expect(system.texts == [String(decoding: written, as: UTF8.self)])
        #expect(result.stdout.first == "There is no configuration at ~/.config/blackice/blackice.toml yet, so a few questions first.")
        #expect(result.stdout.contains("✓ Wrote ~/.config/blackice/blackice.toml: accept-all mode, no rules, no hooks."))
        #expect(result.stdout.last == "✓ Wrote ~/.config/blackice/blackice.toml: accept-all mode, no rules, no hooks.")
        #expect(!result.stdout.contains { $0.hasPrefix("Using ") })
        #expect(terminal.prompts == ["Mode [1]: "])

        // Control-D: nothing written, nothing started.
        let quit = FakeTerminal([])
        let untouched = Started()
        let aborted = run(["start", "--config", NSHomeDirectory() + "/x.toml"], quit, system: untouched)
        #expect(aborted.status == 66 && aborted.stderr == ["Nothing was written."])
        #expect(quit.files.isEmpty && untouched.texts.isEmpty)
    }

    @Test func initWritesOnceAndNeedsATerminal() {
        let terminal = FakeTerminal(["1"])
        let first = run(["init"], terminal)
        #expect(first.status == 0 && terminal.files[CLI.defaultConfigPath] != nil)
        #expect(first.stdout.last == "Start filtering with it: blackice start")

        let again = run(["init"], terminal)
        #expect(again.status == ExitCode.cannotCreate)
        #expect(again.stderr == ["~/.config/blackice/blackice.toml is already there. Edit it, then check it with: " +
                                 "blackice validate ~/.config/blackice/blackice.toml"])

        let other = FakeTerminal(["3", ""])
        let custom = run(["init", "--config", NSHomeDirectory() + "/strict.toml"], other)
        #expect(custom.status == 0 && custom.stdout.last == "Start filtering with it: blackice start --config ~/strict.toml")

        let out = Recorder<String>(), err = Recorder<String>()
        let status = CLI.run(["init"], stdout: { out.append($0) }, stderr: { err.append($0) }, interaction: .none)
        #expect(status == ExitCode.usage && err.items == ["blackice init asks a few questions, so it needs a terminal."])
        #expect(usageError(["init", "now"]) == "init: unexpected argument 'now'")
    }

    @Test func identitiesAreDescribedPlainly() {
        #expect(ConfigWizard.describe(Self.curl) == "com.apple.curl, signed by Apple")
        #expect(ConfigWizard.describe(Self.slack) == "com.tinyspeck.slackmacgap, team BQR82RBBHL")
    }

    @Test func version() {
        #expect(run(["version"], FakeTerminal([])).stdout == ["blackice 0.2.0 (build 6)"])
        #expect(run(["--version"], FakeTerminal([])).status == 0)
        let out = Recorder<String>()
        _ = CLI.run(["version"], stdout: { out.append($0) }, stderr: { _ in })
        #expect(out.items == ["blackice (a build outside Blackice.app)"])
    }

    @Test func createFileNeverReplacesOne() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let path = directory.appendingPathComponent("new/blackice.toml").path
        try CLI.createFile(path, Data("mode = \"ask\"\n".utf8))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mode = \"ask\"\n")
        #expect(try permissions(URL(fileURLWithPath: path)) == 0o644)
        #expect(try permissions(directory.appendingPathComponent("new")) == 0o700)
        #expect(throws: (any Error).self) { try CLI.createFile(path, Data("mode = \"block-all\"\n".utf8)) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mode = \"ask\"\n")
    }

    @Test func missingFileErrorsAreRecognized() {
        #expect(CLI.isMissingFile(CocoaError(.fileReadNoSuchFile)))
        #expect(CLI.isMissingFile(CocoaError(.fileNoSuchFile)))
        #expect(CLI.isMissingFile(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(!CLI.isMissingFile(CocoaError(.fileReadNoPermission)))
        #expect(throws: (any Error).self) { _ = try CLI.readConfigFile("/nonexistent/blackice.toml") }
        do { _ = try CLI.readConfigFile("/nonexistent/blackice.toml") } catch { #expect(CLI.isMissingFile(error)) }
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

struct ReportTests {
    private func snapshot(_ mode: Mode, _ text: String = "mode = \"accept-all\"\n") throws -> ProviderConfiguration {
        try ProviderConfiguration(generation: 3, mode: mode, configText: text)
    }

    private let withHook = """
        mode = "ask"
        timeout_seconds = 60

        [[allow]]
        app = "com.apple.curl"
        hosts = ["pypi.org"]

        [[hook]]
        on = "connection"
        run = "true"

        """

    @Test func statusSaysWhatIsGoingOn() throws {
        #expect(CLI.statusLines(StatusReport(filter: .notConfigured, daemonRunning: false, pending: nil))
            == ["blackice is off. Start it with: blackice start"])
        #expect(CLI.statusLines(StatusReport(filter: .disabled, daemonRunning: false, pending: nil)).count == 2)

        let empty = PendingReply(events: [], approvals: [])
        #expect(CLI.statusLines(StatusReport(filter: .on(try snapshot(.acceptAll)), daemonRunning: false, pending: empty)) == [
            "blackice is on, in accept-all mode: every connection goes through and is logged.",
            "  rules      none",
            "  hooks      none",
            "  waiting    nothing",
        ])

        let tool = AppReference(signingID: "com.apple.curl", teamID: nil, cdhash: nil)
        let busy = PendingReply(
            events: [PendingSummary(id: "ev-0000002a", app: tool, path: nil, host: "example.com", ip: "203.0.113.7",
                                    port: 443, secondsLeft: 8, connections: 3)],
            approvals: [ApprovalSummary(app: tool, host: "pypi.org", secondsLeft: 60)])
        #expect(CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: false, pending: busy)) == [
            "blackice is on, in ask mode: connections no rule covers wait until you, or a hook, answers.",
            "  rules      1 app allowed in every mode",
            "  hooks      1, but the daemon is not running: blackice agent install",
            "  answer in  60 s, or the connection is denied",
            "  waiting    1 app and host (3 connections): blackice pending",
            "  approvals  1 approval",
        ])
        let unreachable = CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: true, pending: nil))
        #expect(unreachable[2] == "  hooks      1, run by the daemon")
        #expect(unreachable.last == "  filter     not answering. If blackice was just upgraded, restart the Mac.")
    }

    @Test func modeAndFirstStartHints() throws {
        #expect(CLI.modeChangedLines(try snapshot(.blockAll), daemonRunning: false)
            == ["✓ Now in block-all mode: only connections your rules allow go through."])
        #expect(CLI.modeChangedLines(try snapshot(.ask), daemonRunning: false).last
            == "See what is waiting with blackice pending, and answer with blackice approve or deny.")
        #expect(CLI.modeChangedLines(try snapshot(.ask, withHook), daemonRunning: false).last
            == "Your hooks need the daemon, which is not running: blackice agent install")
        #expect(CLI.modeChangedLines(try snapshot(.ask, withHook), daemonRunning: true).count == 1)

        let first = CLI.firstStartLines(try snapshot(.acceptAll), daemonRunning: false)
        #expect(first.contains("  blackice mode ask        hold new connections until you, or a hook, answers"))
        #expect(CLI.firstStartLines(try snapshot(.ask, withHook), daemonRunning: false)
            .contains("  blackice agent install   run your hooks for those connections"))
    }

    @Test func describe() {
        #expect(Describe.count(0, "rule") == "no rules" && Describe.count(1, "rule") == "1 rule" && Describe.count(2, "rule") == "2 rules")
        #expect(Describe.path("/Users/test/.config/blackice/blackice.toml", home: "/Users/test") == "~/.config/blackice/blackice.toml")
        #expect(Describe.path("/Users/tester/x", home: "/Users/test") == "/Users/tester/x")
        #expect(Describe.path("n.toml", home: "/Users/test") == "n.toml")
    }
}
