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
    var setups: [Bool] = []
    func start(configText: String, output: SystemOutput) -> Int32 { texts.append(configText); setups.append(output.setup); return 0 }
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

private func answers(_ script: [String], paths: Set<String> = [], identities: [String: SigningIdentity] = [:],
                     said: Recorder<String> = Recorder<String>()) -> ConfigWizard.Answers? {
    let terminal = FakeTerminal(script, paths: paths, identities: identities)
    return ConfigWizard(ask: { prompt in said.append(prompt); return terminal.interaction.ask!(prompt) },
                        say: said.append, identify: { identities[$0] },
                        fileExists: { paths.contains($0) }, home: "/Users/test").run()
}

/// The wizard with lists: `picks` answers each list in turn, `script` each typed question.
private func pickedAnswers(_ picks: [[Int]?], script: [String] = [], running: [String] = [],
                           paths: Set<String> = [], identities: [String: SigningIdentity] = [:],
                           choices: Recorder<Choice> = Recorder<Choice>(), said: Recorder<String> = Recorder<String>())
    -> ConfigWizard.Answers? {
    var picks = picks
    let terminal = FakeTerminal(script, paths: paths, identities: identities)
    return ConfigWizard(ask: { prompt in said.append(prompt); return terminal.interaction.ask!(prompt) },
                        say: said.append, identify: { identities[$0] }, fileExists: { paths.contains($0) },
                        home: "/Users/test",
                        choose: { choice in choices.append(choice); return picks.isEmpty ? nil : picks.removeFirst() },
                        runningApps: { running }).run()
}

struct WizardTests {
    static let curl = SigningIdentity(signingID: "com.apple.curl", teamID: nil)
    static let slack = SigningIdentity(signingID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL")

    @Test func listsPickTheModeTheAgentAndTheApps() {
        // accept-all: one list, nothing else.
        let choices = Recorder<Choice>()
        #expect(pickedAnswers([[0]], choices: choices) == ConfigWizard.Answers())
        #expect(choices.items.count == 1 && choices.items[0].options.count == 3 && !choices.items[0].multiple)

        // ask, fx answers, Slack trusted; an unsigned app is not offered.
        let asked = Recorder<Choice>(), said = Recorder<String>()
        let ask = pickedAnswers([[1], [0], [0]], running: ["/Applications/Slack.app", "/Applications/Unsigned.app"],
                                identities: ["/Applications/Slack.app": Self.slack], choices: asked, said: said)
        #expect(ask == ConfigWizard.Answers(mode: .ask, rules: [.init(identity: Self.slack, hosts: ["*"])], agent: "fx"))
        #expect(asked.items.map(\.multiple) == [false, false, true])
        #expect(asked.items[2].options == ["Slack", "Another app: type its path or name"])
        #expect(said.items.contains("    ✓ Slack may reach any host (com.tinyspeck.slackmacgap)"))
        #expect(said.items.allSatisfy { $0.count <= 78 })

        // ask, answered by the person, no apps.
        #expect(pickedAnswers([[1], [1], []]) == ConfigWizard.Answers(mode: .ask))

        // block-all with another app, typed.
        let other = pickedAnswers([[2], [0]], script: ["/usr/bin/curl", "pypi.org", ""], paths: ["/usr/bin/curl"],
                                  identities: ["/usr/bin/curl": Self.curl])
        #expect(other == ConfigWizard.Answers(mode: .blockAll, rules: [.init(identity: Self.curl, hosts: ["pypi.org"])]))

        // Cancelling any list writes nothing.
        #expect(pickedAnswers([nil]) == nil)
        #expect(pickedAnswers([[1], nil]) == nil)
        #expect(pickedAnswers([[1], [0], nil]) == nil)
    }

    @Test func runningAppsAreTheirBundles() {
        let home = "/Users/test"
        #expect(Interaction.appBundle("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                                      home: home) == "/Applications/Slack.app")
        #expect(Interaction.appBundle("/Users/test/Applications/Tool.app/Contents/MacOS/Tool", home: home)
            == "/Users/test/Applications/Tool.app")
        #expect(Interaction.appBundle("/System/Applications/Mail.app/Contents/MacOS/Mail", home: home) == nil)
        #expect(Interaction.appBundle("/usr/bin/curl", home: home) == nil)
        #expect(Interaction.appBundle("/Applications/Blackice.app/Contents/MacOS/blackice", home: home) == nil)
        #expect(Interaction.appName("/Applications/Brave Browser.app") == "Brave Browser")
        // A VPN client's network extension runs from /Library/SystemExtensions; blackice's own does not count.
        let tailscale = "/Library/SystemExtensions/00000000-0000-4000-8000-000000000000/" +
            "io.tailscale.ipn.macsys.network-extension.systemextension"
        #expect(Interaction.appBundle(tailscale + "/Contents/MacOS/io.tailscale.ipn.macsys.network-extension",
                                      home: home) == tailscale)
        #expect(Interaction.appBundle("/Library/SystemExtensions/AF7EA933-B838-44A4-8349-AA0D21DB7949/" +
                                      "com.valentorassa.blackice.filter.systemextension/Contents/MacOS/" +
                                      "com.valentorassa.blackice.filter", home: home) == nil)
        #expect(Interaction.appBundle("/Library/SystemExtensions/db.plist", home: home) == nil)
        // With no Info.plist to read, a system extension is named by its file.
        #expect(Interaction.appName(tailscale) == "io.tailscale.ipn.macsys.network-extension")
    }

    @Test func enterTakesTheDefaults() throws {
        let result = try #require(answers([""]))
        #expect(result == ConfigWizard.Answers(mode: .acceptAll, timeoutSeconds: 60, rules: []))
        let text = ConfigWizard.render(result)
        let config = try BlackiceConfig(data: Data(text.utf8))
        #expect(config.mode == .acceptAll && config.timeoutSeconds == 60 && config.allow.isEmpty)
        #expect(text.hasPrefix("# blackice configuration, written by blackice.\n"))
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
        let said = Recorder<String>()
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
            paths: ["/tmp/adhoc"], said: said))
        #expect(result.mode == .blockAll)
        #expect(result.rules == [.init(identity: Self.curl, hosts: ["pypi.org"])])
        // Every line fits an 80-column Terminal window, and sits under the step's title.
        #expect(said.items.allSatisfy { $0.count <= 78 && ($0.isEmpty || $0.hasPrefix("  ")) })
        #expect(said.items.contains("    Type 1, 2 or 3."))

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
        #expect(system.setups == [true])
        #expect(Array(result.stdout.prefix(5)) == [
            "Setting up blackice: pick a mode, confirm with Touch ID, then allow its",
            "network extension if macOS asks.",
            "",
            "1 · Pick a mode",
            "",
        ])
        #expect(Array(result.stdout.suffix(2)) == [
            "  ✓ Saved ~/.config/blackice/blackice.toml",
            "    Accept-all mode, no rules, no hooks. Edit it any time.",
        ])
        #expect(!result.stdout.contains { $0.hasPrefix("Using ") })
        #expect(result.stdout.allSatisfy { $0.count <= 78 })
        #expect(terminal.prompts == ["  Mode [1]: "])

        // With a file already there: no steps.
        let again = run(["start"], terminal, system: system)
        #expect(again.status == 0 && system.setups == [true, false])
        #expect(again.stdout == ["Using ~/.config/blackice/blackice.toml: accept-all mode, no rules, no hooks."])

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
        let upgraded = CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: true, pending: nil,
                                                    upgrade: UnfinishedUpgrade(app: "16", running: ["15"])))
        #expect(upgraded.last == "  filter     still build 15, and this app is build 16: run blackice start to finish the upgrade")
    }

    /// The app was replaced and start has not activated its extension: macOS still runs another build.
    @Test func anUnfinishedUpgradeIsTold() throws {
        let upgrade = try #require(UnfinishedUpgrade(app: "16", running: ["15"]))
        #expect(upgrade.running == "15")
        #expect(upgrade.hint == "blackice was upgraded to build 16, but macOS still runs the network extension of build 15. " +
                "Run blackice start to finish the upgrade.")
        #expect(UnfinishedUpgrade(app: "10", running: ["9"])?.running == "9")
        // The app's build runs (also next to an older one), a newer one runs (start would refuse it), none runs,
        // or a build is unknown.
        #expect(UnfinishedUpgrade(app: "16", running: ["16"]) == nil)
        #expect(UnfinishedUpgrade(app: "16", running: ["15", "16"]) == nil)
        #expect(UnfinishedUpgrade(app: "16", running: ["16.0"]) == nil)
        #expect(UnfinishedUpgrade(app: "16", running: ["17"]) == nil)
        #expect(UnfinishedUpgrade(app: "16", running: []) == nil)
        #expect(UnfinishedUpgrade(app: "16", running: ["x"]) == nil)
        #expect(UnfinishedUpgrade(app: nil, running: ["15"]) == nil)
        #expect(UnfinishedUpgrade(app: "x", running: ["15"]) == nil)
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
        #expect(first.contains("  blackice mode ask          hold new connections until you or a hook answers"))
        #expect(CLI.firstStartLines(try snapshot(.ask, withHook), daemonRunning: false)
            .contains("  blackice agent install     run your hooks for those connections"))
        let ask = CLI.firstStartLines(try snapshot(.ask), daemonRunning: false)
        #expect(ask.contains("  blackice agent connect fx  let fx answer them"))
        #expect(!CLI.firstStartLines(try snapshot(.ask, withHook), daemonRunning: false).contains { $0.contains("agent connect") })
    }

    @Test func startSaysWhatItDidOnTwoLines() throws {
        #expect(CLI.onLines(try snapshot(.blockAll)) == [
            "✓ blackice is on, in block-all mode.",
            "  Only connections your rules allow go through.",
        ])
    }

    @Test func approvalStepsFollowTheMacOSVersion() {
        let tahoe = ExtensionApproval.lines(macOS: 27, opened: true, setup: true)
        #expect(tahoe == [
            "",
            "3 · Allow the network extension",
            "",
            "  System Settings is open at General › Login Items. There:",
            "",
            "    1. Scroll to Blackice in the list and click ⓘ next to it.",
            "    2. Turn on Network Extension, then click Done.",
            "",
            "  Waiting for you (up to 10 minutes)…",
        ])
        #expect(ExtensionApproval.lines(macOS: 26, opened: false, setup: false)[1...3] == [
            "Allow the network extension", "", "  Open System Settings › General › Login Items. There:"])
        #expect(ExtensionApproval.lines(macOS: 15, opened: true, setup: true)
            .contains("    1. Under Extensions, click ⓘ next to Network Extensions."))
        #expect(ExtensionApproval.lines(macOS: 14, opened: true, setup: true)
            .contains("  System Settings is open at Privacy & Security. There:"))
        for major in [14, 15, 26, 27] {
            #expect(ExtensionApproval.lines(macOS: major, opened: true, setup: true).allSatisfy { $0.count <= 78 })
        }
        #expect(ExtensionApproval.settingsURL(macOS: 27) == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        #expect(ExtensionApproval.settingsURL(macOS: 14) == "x-apple.systempreferences:com.apple.preference.security")
        #expect(("  " + ExtensionApproval.filterPrompt).count <= 78)
    }

    @Test func styleIsPlainUnlessATerminalAsks() {
        #expect(Style.wrap("Done", "1", enabled: false) == "Done")
        #expect(Style.wrap("Done", "1", enabled: true) == "\u{1B}[1mDone\u{1B}[0m")
        #expect(Style.done("Saved") == "✓ Saved")
    }

    @Test func describe() {
        #expect(Describe.count(0, "rule") == "no rules" && Describe.count(1, "rule") == "1 rule" && Describe.count(2, "rule") == "2 rules")
        #expect(Describe.path("/Users/test/.config/blackice/blackice.toml", home: "/Users/test") == "~/.config/blackice/blackice.toml")
        #expect(Describe.path("/Users/tester/x", home: "/Users/test") == "/Users/tester/x")
        #expect(Describe.path("n.toml", home: "/Users/test") == "n.toml")
    }
}
