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
    var asWritten: [Bool] = []
    func start(configText: String, output: SystemOutput) -> Int32 {
        texts.append(configText); setups.append(output.setup); asWritten.append(output.asWritten); return 0
    }
    func stop(output: SystemOutput) -> Int32 { 0 }
    func status(output: SystemOutput) -> Int32 { 0 }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { 0 }
    func pending(output: SystemOutput) -> Int32 { 0 }
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { 0 }
    func forgetApprovals(output: SystemOutput) -> Int32 { 0 }
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
private func pickedAnswers(_ picks: [[Int]?], script: [String] = [], running: [String] = [], extensions: [String] = [],
                           helpers: [String: [String]] = [:], proxies: Set<String> = [],
                           paths: Set<String> = [], identities: [String: SigningIdentity] = [:],
                           choices: Recorder<Choice> = Recorder<Choice>(), said: Recorder<String> = Recorder<String>())
    -> ConfigWizard.Answers? {
    var picks = picks
    let terminal = FakeTerminal(script, paths: paths, identities: identities)
    return ConfigWizard(ask: { prompt in said.append(prompt); return terminal.interaction.ask!(prompt) },
                        say: said.append, identify: { identities[$0] }, fileExists: { paths.contains($0) },
                        home: "/Users/test",
                        choose: { choice in choices.append(choice); return picks.isEmpty ? nil : picks.removeFirst() },
                        runningApps: { running }, networkExtensions: { extensions },
                        helpers: { helpers[$0] ?? [] }, isTunnel: { !proxies.contains($0) }).run()
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
        // Each list carries its question, and once picked the question stays with the answer.
        #expect(asked.items.map(\.prompt) == ["  How should blackice treat new connections?", "  Who answers when blackice holds a connection?",
                                              "  Which apps may connect anywhere, in every mode?"])
        #expect(asked.items[0].answer([1]) == "ask" && asked.items[1].answer([0]) == "fx" && asked.items[2].answer([0]) == "Slack")
        #expect(asked.items[2].answer([]) == "none")
        #expect(said.items.isEmpty)

        // ask, Claude Code answers; ask, answered by the person, no apps. Codex and opencode are not
        // offered for now: `blackice agent connect` sets them up.
        let agents = Recorder<Choice>()
        #expect(pickedAnswers([[1], [1], []], choices: agents) == ConfigWizard.Answers(mode: .ask, agent: "claude-code"))
        #expect(agents.items[1].options.count == 3 && agents.items[1].options[1].hasPrefix("Claude Code: "))
        #expect(agents.items[1].options[2].hasPrefix("Me, "))
        #expect(agents.items[1].options.allSatisfy { $0.count <= 74 })
        #expect(pickedAnswers([[1], [2], []]) == ConfigWizard.Answers(mode: .ask))

        // block-all with another app, typed.
        let other = pickedAnswers([[2], [0]], script: ["/usr/bin/curl", "pypi.org", ""], paths: ["/usr/bin/curl"],
                                  identities: ["/usr/bin/curl": Self.curl])
        #expect(other == ConfigWizard.Answers(mode: .blockAll, rules: [.init(identity: Self.curl, hosts: ["pypi.org"])]))

        // Cancelling any list writes nothing.
        #expect(pickedAnswers([nil]) == nil)
        #expect(pickedAnswers([[1], nil]) == nil)
        #expect(pickedAnswers([[1], [0], nil]) == nil)
    }

    /// An app named with escape sequences could clear its row and draw another app's name over it,
    /// so the one picked to reach any host is not the one the person saw. Its name is escaped.
    @Test func appNamesCannotRedrawTheList() {
        let bundle = "/Users/test/Applications/Evil\u{1B}[2K\rSlack.app"
        let evil = SigningIdentity(signingID: "com.example.evil", teamID: "ABCDE12345")
        let choices = Recorder<Choice>(), said = Recorder<String>()
        let picked = pickedAnswers([[2], [0]], running: [bundle], identities: [bundle: evil], choices: choices, said: said)
        #expect(picked?.rules == [.init(identity: evil, hosts: ["*"])])
        #expect(choices.items[1].options.first == "Evil\\u{1b}[2K\\u{d}Slack")
        #expect(choices.items[1].answer([0]) == "Evil\\u{1b}[2K\\u{d}Slack")
        #expect(!said.items.joined().unicodeScalars.contains("\u{1B}"))
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

    /// `systemextensionsctl list` on the owner's Mac on 6 November 2026, shortened: blackice's filter,
    /// with older builds waiting for a restart to go, two VPN clients' and a camera extension.
    static let listing = """
        7 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tM294LK997M\tcom.valentorassa.blackice.filter (0.4.2/23)\tBlackice Filter\t[terminated waiting to uninstall on reboot]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (6.2.0/2791919.2512111400)\tProton VPN WireGuard\t[activated enabled]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.Transparent-Proxy (6.2.0/2791919.2512111400)\tProton VPN Split Tunneling (experimental)\t[activated enabled]
        *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.104.2/101.104.2)\tTailscale Network Extension\t[activated enabled]
        *\t*\tM294LK997M\tcom.valentorassa.blackice.filter (0.4.7/28)\tBlackice Filter\t[activated enabled]
        --- com.apple.system_extension.cmio (Go to 'System Settings > General > Login Items & Extensions > Camera Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\t2MMRE5MTB8\tcom.obsproject.obs-studio.mac-camera-extension (32.2.2/31845296735)\tOBS Virtual Camera\t[activated waiting for user]

        """

    @Test func activatedNetworkExtensionsAreRead() {
        let wireGuard = Interaction.ListedExtension(teamID: "J6S6Q257EK", bundleID: "ch.protonvpn.mac.WireGuard-Extension",
                                                    name: "Proton VPN WireGuard")
        let tailscale = Interaction.ListedExtension(teamID: "W5364U7YZB", bundleID: "io.tailscale.ipn.macsys.network-extension",
                                                    name: "Tailscale Network Extension")
        let listed = Interaction.activatedNetworkExtensions(Self.listing)
        #expect(listed.map(\.bundleID) == ["ch.protonvpn.mac.WireGuard-Extension", "ch.protonvpn.mac.Transparent-Proxy",
                                           "io.tailscale.ipn.macsys.network-extension"])
        #expect(listed.first == wireGuard && listed.last == tailscale)
        #expect(listed[1].name == "Proton VPN Split Tunneling (experimental)")

        // Older macOS prints the category alone. Only activated and enabled network extensions count,
        // with a Team ID and a bundle ID a path can hold; anything else is skipped.
        let other = """
            --- com.apple.system_extension.network_extension
            enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
            *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.104.2/101.104.2)\tTailscale Network Extension\t[activated enabled]
            \t\tABCDE12345\tcom.example.off (1.0/1)\tTurned Off\t[activated disabled]
            \t*\tABCDE12345\tcom.example.waiting (1.0/1)\tWaiting\t[activated waiting for user]
            *\t*\t-\tcom.example.noteam (1.0/1)\tNo Team\t[activated enabled]
            *\t*\tABCDE12345\t../evil (1.0/1)\tSlash\t[activated enabled]
            *\t*\tABCDE12345\tcom.example.short (1.0/1)\t[activated enabled]
            not a row
            --- com.apple.system_extension.endpoint_security
            enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
            *\t*\tABCDE12345\tcom.example.security (1.0/1)\tSecurity\t[activated enabled]
            """
        #expect(Interaction.activatedNetworkExtensions(other) == [tailscale])
        #expect(Interaction.activatedNetworkExtensions("").isEmpty)
        #expect(Interaction.activatedNetworkExtensions("0 extension(s)\n").isEmpty)

        // Each one's bundle, in one of the folders macOS names by UUIDs; an upgrade keeps the old
        // folder until a restart, and an extension with no bundle there is left out.
        let old = "0F657535-8EDF-4212-AD21-316A5D5CC550", new = "E0C0FCB8-C157-44E5-97F8-E978DC5FDB1F"
        let bundles: Set = ["/Library/SystemExtensions/\(new)/io.tailscale.ipn.macsys.network-extension.systemextension",
                            "/Library/SystemExtensions/\(old)/io.tailscale.ipn.macsys.network-extension.systemextension"]
        #expect(Interaction.extensionBundles([tailscale, wireGuard], folders: ["db.plist", new, old, ".staging"],
                                             fileExists: { bundles.contains($0) })
            == ["/Library/SystemExtensions/\(old)/io.tailscale.ipn.macsys.network-extension.systemextension"])
        #expect(Interaction.extensionBundles([tailscale], folders: [], fileExists: { _ in true }).isEmpty)
    }

    /// The network extensions macOS has activated come first in the list of apps to trust, ticked,
    /// whether they run or not; each picked one may reach any host, as a VPN client's needs.
    @Test func networkExtensionsAreListedFirstAndTicked() throws {
        // Folders no Mac has, so the names come from the bundles' file names.
        let tailscalePath = "/Library/SystemExtensions/00000000-0000-4000-8000-000000000001/" +
            "io.tailscale.ipn.macsys.network-extension.systemextension"
        let protonPath = "/Library/SystemExtensions/00000000-0000-4000-8000-000000000002/" +
            "ch.protonvpn.mac.WireGuard-Extension.systemextension"
        let tailscale = SigningIdentity(signingID: "io.tailscale.ipn.macsys.network-extension", teamID: "W5364U7YZB")
        let proton = SigningIdentity(signingID: "ch.protonvpn.mac.WireGuard-Extension", teamID: "J6S6Q257EK")
        let identities = [tailscalePath: tailscale, protonPath: proton, "/Applications/Slack.app": Self.slack]
        let choices = Recorder<Choice>()
        // Tailscale's runs, so it is among the running apps too; it is listed once.
        let picked = pickedAnswers([[2], [0, 2]], running: ["/Applications/Slack.app", tailscalePath],
                                   extensions: [tailscalePath, protonPath], identities: identities, choices: choices)
        let answers = try #require(picked)
        #expect(choices.items[1].options == ["io.tailscale.ipn.macsys.network-extension", "ch.protonvpn.mac.WireGuard-Extension",
                                             "Slack", "Another app: type its path or name"])
        // Slack is a common app, so it is ticked too.
        #expect(choices.items[1].initial == [0, 1, 2] && choices.items[1].multiple)
        #expect(answers.rules == [.init(identity: tailscale, hosts: ["*"]), .init(identity: Self.slack, hosts: ["*"])])
        let text = ConfigWizard.render(answers)
        #expect(text.contains("[[allow]]\napp = \"io.tailscale.ipn.macsys.network-extension\"\nteam = \"W5364U7YZB\"\nhosts = [\"*\"]\n"))
        #expect(try BlackiceConfig(data: Data(text.utf8)).anyHostRule(for: tailscale) != nil)

        // Unticked, it gets no rule; with none activated and no common app, nothing is ticked.
        #expect(pickedAnswers([[2], []], extensions: [tailscalePath], identities: identities)?.rules == [])
        let plain = Recorder<Choice>()
        _ = pickedAnswers([[2], []], running: ["/Applications/Notes Tool.app"],
                          identities: ["/Applications/Notes Tool.app": SigningIdentity(signingID: "com.example.notes", teamID: "ABCDE12345")],
                          choices: plain)
        #expect(plain.items[1].initial.isEmpty)
    }

    /// The common apps that run come right after the network extensions, ticked; a picked app's rules
    /// cover its helpers signed by the same team, since the helper is what connects.
    @Test func commonAppsAreTickedWithTheirHelpers() throws {
        let chrome = SigningIdentity(signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        let chromeHelper = SigningIdentity(signingID: "com.google.Chrome.helper", teamID: "EQHXZ8M8AV")
        let renderer = SigningIdentity(signingID: "com.google.Chrome.helper.renderer", teamID: "EQHXZ8M8AV")
        let foreign = SigningIdentity(signingID: "com.example.bundled", teamID: "ZZZZZ99999")
        let fake = SigningIdentity(signingID: "com.google.Chrome", teamID: "ABCDE12345")
        let notes = SigningIdentity(signingID: "com.example.notes", teamID: "ABCDE12345")
        let chromePath = "/Applications/Google Chrome.app"
        let helperPath = chromePath + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app"
        let rendererPath = chromePath + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app"
        let foreignPath = chromePath + "/Contents/Frameworks/Bundled.app"
        let again = chromePath + "/Contents/Frameworks/Copy.app"
        let identities = [chromePath: chrome, helperPath: chromeHelper, rendererPath: renderer, foreignPath: foreign,
                          again: chromeHelper, "/Applications/Notes Tool.app": notes, "/Applications/Not Chrome.app": fake,
                          "/Applications/Slack.app": Self.slack]
        let choices = Recorder<Choice>()
        let picked = pickedAnswers([[2], [0, 1, 2, 3]],
                                   running: ["/Applications/Not Chrome.app", chromePath, "/Applications/Notes Tool.app", "/Applications/Slack.app"],
                                   helpers: [chromePath: [helperPath, rendererPath, foreignPath, again],
                                             "/Applications/Not Chrome.app": [helperPath]],
                                   identities: identities, choices: choices)
        let answers = try #require(picked)
        // Chrome and Slack first and ticked; the lookalike with another Team ID and Notes after, unticked.
        #expect(choices.items[1].options == ["Google Chrome", "Slack", "Not Chrome", "Notes Tool", "Another app: type its path or name"])
        #expect(choices.items[1].initial == [0, 1])
        // Chrome's helpers of its own team, once each; a bundled helper of another team gets nothing, and
        // so does the lookalike's helper, whose team is not the lookalike's.
        #expect(answers.rules == [chrome, chromeHelper, renderer, Self.slack, fake, notes].map { .init(identity: $0, hosts: ["*"]) })
        let config = try BlackiceConfig(data: Data(ConfigWizard.render(answers).utf8))
        #expect(config.anyHostRule(for: chromeHelper) != nil && config.anyHostRule(for: foreign) == nil)
    }

    /// The helpers are the outermost .app, .xpc and .appex bundles inside the app's Contents.
    @Test func helperBundlesAreTheOutermostNestedBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-helpers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Tool.app").path
        for folder in ["Contents/MacOS", "Contents/Frameworks/Tool Framework.framework/Helpers/Tool Helper.app/Contents/PlugIns/Inner.appex",
                       "Contents/XPCServices/Fetch.xpc", "Contents/PlugIns/Share.appex", "Contents/Resources/Icons"] {
            try FileManager.default.createDirectory(atPath: app + "/" + folder, withIntermediateDirectories: true)
        }
        #expect(Interaction.helperBundles(inside: app).allSatisfy { $0.hasPrefix(app + "/Contents/") })
        let found = Set(Interaction.helperBundles(inside: app).map { String($0.dropFirst(app.count)) })
        #expect(found == ["/Contents/Frameworks/Tool Framework.framework/Helpers/Tool Helper.app",
                          "/Contents/XPCServices/Fetch.xpc", "/Contents/PlugIns/Share.appex"])
        #expect(Interaction.helperBundles(inside: root.path).isEmpty)
    }

    /// A network extension that is a proxy, such as a VPN client's split tunneling, carries other apps'
    /// connections: it is listed after the tunnels and common apps, unticked. Its Info.plist says which.
    @Test func proxyExtensionsAreListedUnticked() throws {
        let tunnelPath = "/Library/SystemExtensions/00000000-0000-4000-8000-000000000001/io.tailscale.ipn.macsys.network-extension.systemextension"
        let proxyPath = "/Library/SystemExtensions/00000000-0000-4000-8000-000000000003/ch.protonvpn.mac.Transparent-Proxy.systemextension"
        let tunnel = SigningIdentity(signingID: "io.tailscale.ipn.macsys.network-extension", teamID: "W5364U7YZB")
        let proxy = SigningIdentity(signingID: "ch.protonvpn.mac.Transparent-Proxy", teamID: "J6S6Q257EK")
        let choices = Recorder<Choice>()
        let picked = pickedAnswers([[2], [0]], running: ["/Applications/Slack.app"], extensions: [proxyPath, tunnelPath],
                                   proxies: [proxyPath], identities: [tunnelPath: tunnel, proxyPath: proxy, "/Applications/Slack.app": Self.slack],
                                   choices: choices)
        #expect(choices.items[1].options.prefix(3) == ["io.tailscale.ipn.macsys.network-extension", "Slack", "ch.protonvpn.mac.Transparent-Proxy"])
        #expect(choices.items[1].initial == [0, 1])
        #expect(try #require(picked).rules == [.init(identity: tunnel, hosts: ["*"])])

        // The plist: a packet tunnel provider is a tunnel; an app proxy, or no plist, is not.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-tunnel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, _ classes: [String]) throws -> String {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            let info: NSDictionary = ["NetworkExtension": ["NEProviderClasses": Dictionary(uniqueKeysWithValues: classes.map { ($0, "X") })]]
            #expect(info.write(toFile: path + "/Contents/Info.plist", atomically: true))
            return path
        }
        #expect(Interaction.isTunnel(try bundle("t.systemextension", ["com.apple.networkextension.packet-tunnel"])))
        #expect(!Interaction.isTunnel(try bundle("p.systemextension", ["com.apple.networkextension.app-proxy"])))
        #expect(!Interaction.isTunnel(root.appendingPathComponent("none.systemextension").path))
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
        // The file just written is loaded as written, mode and answers included.
        #expect(system.asWritten == [true])
        #expect(Array(result.stdout.prefix(2)) == ["1 · Pick a mode", "  How should blackice treat new connections?"])
        #expect(result.stdout.last == "  ✓ Saved ~/.config/blackice/blackice.toml: accept-all mode, no rules")
        #expect(!result.stdout.contains { $0.hasPrefix("Using ") })
        #expect(result.stdout.allSatisfy { $0.count <= 78 })
        #expect(terminal.prompts == ["  Mode [1]: "])

        // With a file already there: no steps.
        let again = run(["start"], terminal, system: system)
        #expect(again.status == 0 && system.setups == [true, false])
        // A later start keeps a switch made with blackice mode or the menu.
        #expect(system.asWritten == [true, false])
        #expect(again.stdout.isEmpty)

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
        #expect(first.stdout.suffix(2) == ["  ✓ Saved ~/.config/blackice/blackice.toml: accept-all mode, no rules", "Next: blackice start"])

        let again = run(["init"], terminal)
        #expect(again.status == ExitCode.cannotCreate)
        #expect(again.stderr == ["~/.config/blackice/blackice.toml is already there. Check it with: " +
                                 "blackice validate ~/.config/blackice/blackice.toml"])

        let other = FakeTerminal(["3", ""])
        let custom = run(["init", "--config", NSHomeDirectory() + "/strict.toml"], other)
        #expect(custom.status == 0 && custom.stdout.last == "Next: blackice start --config ~/strict.toml")

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
            == ["blackice is off. Start it: blackice start"])
        #expect(CLI.statusLines(StatusReport(filter: .disabled, daemonRunning: false, pending: nil)).count == 1)

        let empty = PendingReply(events: [], approvals: []).deciding(with: try snapshot(.acceptAll))
        #expect(CLI.statusLines(StatusReport(filter: .on(try snapshot(.acceptAll)), daemonRunning: false, pending: empty)) == [
            "blackice is on in accept-all mode",
            "  rules      none",
            "  next       blackice agent connect fx, or blackice mode ask",
        ])
        // With a hook, accept-all is a choice made after an agent was connected: no hint.
        let hooked = try snapshot(.acceptAll, withHook)
        #expect(!CLI.statusLines(StatusReport(filter: .on(hooked), daemonRunning: true,
                                              pending: PendingReply(events: [], approvals: []).deciding(with: hooked)))
            .contains { $0.hasPrefix("  next") })

        let tool = AppReference(signingID: "com.apple.curl", teamID: nil, cdhash: nil)
        let busy = PendingReply(
            events: [PendingSummary(id: "ev-0000002a", app: tool, path: nil, host: "example.com", ip: "203.0.113.7",
                                    port: 443, secondsLeft: 8, connections: 3)],
            approvals: [ApprovalSummary(app: tool, host: "pypi.org", secondsLeft: 60)]).deciding(with: try snapshot(.ask, withHook))
        #expect(CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: false, pending: busy)) == [
            "blackice is on in ask mode",
            "  answers    your hooks",
            "  waiting    1 app and host: blackice pending",
            "  rules      1",
            "  approvals  1",
            "  timeout    60 s",
            "  daemon     not running, so no hook runs: blackice agent install",
        ])
        // A denial remembered a moment ago drops the app's connections with no event: status says so.
        let denied = PendingReply(events: [], approvals: [],
                                  denials: [ApprovalSummary(app: tool, host: "example.com", secondsLeft: 540),
                                            ApprovalSummary(app: tool, host: "pypi.org", secondsLeft: 60)])
            .deciding(with: try snapshot(.ask, withHook))
        #expect(CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: true, pending: denied))
            .prefix(5) == [
                "blackice is on in ask mode",
                "  answers    your hooks",
                "  waiting    nothing",
                "  denied     2 apps and hosts a moment ago, dropped without asking: blackice pending",
                "  rules      1",
            ])
        let unreachable = CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: true, pending: nil))
        #expect(unreachable[2] == "  rules      1")
        #expect(unreachable.last == "  filter     not answering; if blackice was just upgraded, restart the Mac")
        let upgraded = CLI.statusLines(StatusReport(filter: .on(try snapshot(.ask, withHook)), daemonRunning: true, pending: nil,
                                                    upgrade: UnfinishedUpgrade(app: "16", running: ["15"])))
        #expect(upgraded.last == "  filter     still build 15, and this app is build 16: blackice start finishes the upgrade")
    }

    /// The app was replaced and start has not activated its extension: macOS still runs another build.
    @Test func anUnfinishedUpgradeIsTold() throws {
        let upgrade = try #require(UnfinishedUpgrade(app: "16", running: ["15"]))
        #expect(upgrade.running == "15")
        #expect(upgrade.hint == "blackice was upgraded to build 16, but macOS still runs build 15's network extension. " +
                "blackice start finishes the upgrade.")
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

    /// The saved configuration is not always the one the filter decides with: it keeps its own when
    /// it refuses the saved one, and status says so instead of naming the saved mode.
    @Test func statusSaysWhenTheFilterHoldsAnotherConfiguration() throws {
        let saved = try ProviderConfiguration(generation: 6, mode: .blockAll, configText: "mode = \"block-all\"\n")
        let held = try ProviderConfiguration(generation: 5, mode: .acceptAll, configText: "mode = \"block-all\"\n")
        let other = PendingReply(events: [], approvals: []).deciding(with: held)
        #expect(CLI.statusLines(StatusReport(filter: .on(saved), daemonRunning: false, pending: other)).prefix(2) == [
            "blackice is on, but its filter decides in accept-all mode (generation 5), not with the saved block-all mode (generation 6).",
            "  Load yours again: blackice start",
        ])
        let none = CLI.statusLines(StatusReport(filter: .on(saved), daemonRunning: false, pending: PendingReply(events: [], approvals: [])))
        #expect(none.first == "blackice is on, but its filter holds no configuration.")
    }

    /// What start and mode make of the filter's answer after they saved a configuration.
    @Test func startAndModeCheckThatTheFilterTookIt() throws {
        let saved = try ProviderConfiguration(generation: 6, mode: .blockAll, configText: "mode = \"block-all\"\n")
        #expect(Activation(PendingReply(events: [], approvals: []).deciding(with: saved), saved: saved) == .active)
        #expect(Activation(nil, saved: saved) == .noAnswer)
        #expect(Activation(PendingReply(events: [], approvals: []), saved: saved) == .other(nil))
        // Same generation and mode, other text: not the one saved.
        let edited = try ProviderConfiguration(generation: 6, mode: .blockAll, configText: "mode = \"block-all\"\n# edited\n")
        #expect(Activation(PendingReply(events: [], approvals: []).deciding(with: edited), saved: saved) == .other(ActiveConfiguration(edited)))
        let previous = try ProviderConfiguration(generation: 5, mode: .acceptAll, configText: "mode = \"block-all\"\n")
        let refusedOne = Activation(PendingReply(events: [], approvals: []).deciding(with: previous), saved: saved)

        #expect(CLI.notActiveLines(saved, .active).isEmpty && CLI.activationStatus(.active) == 0)
        #expect(CLI.notActiveLines(saved, refusedOne).first
            == "blackice's filter did not load generation 6: it decides in accept-all mode (generation 5). Its log says why:")
        #expect(CLI.notActiveLines(saved, refusedOne).last?.contains("subsystem == \"com.valentorassa.blackice.filter\"") == true)
        #expect(CLI.activationStatus(refusedOne) == ExitCode.software)
        #expect(CLI.notActiveLines(saved, .noAnswer).first
            == "block-all mode is saved, but blackice's filter did not answer, so whether it is in force is not known.")
        #expect(CLI.activationStatus(.noAnswer) == ExitCode.unavailable)
        #expect(CLI.notActiveLines(saved, .other(nil)).first?.hasPrefix("blackice's filter holds no configuration") == true)
    }

    /// What start says it keeps from a switch, before Touch ID.
    @Test func startSaysWhatItKeeps() throws {
        let fx = "[[hook]]\non = 'connection'\nprogram = '/opt/fx'\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\ninstructions = 'fx'\n"
        let codex = "[[hook]]\non = 'connection'\nprogram = '/opt/codex'\napp = 'codex'\nteam = '2DC432GLL2'\ninstructions = 'codex'\n"
        let text = "mode = 'ask'\n" + fx + codex + "[agent]\nanswers = 'fx'\n"
        let file = try BlackiceConfig(text: text)
        let switched = try ProviderConfiguration(generation: 4, mode: .ask, configText: text).with(mode: .acceptAll, answerer: .agent(.codex))
        let kept = try ProviderConfiguration.starting(configText: text, after: switched, keepingSwitches: true)
        #expect(CLI.keptLines(kept, file: file) == [
            "Keeping accept-all mode from blackice mode or the menu; the file says ask.",
            "Keeping Codex answering from blackice mode or the menu; the file says fx.",
        ])
        let none = try BlackiceConfig(text: "mode = 'ask'\n" + fx + codex)
        let you = try ProviderConfiguration(generation: 2, mode: .ask, configText: try BlackiceConfig.switchingAnswers(.you, in: "mode = 'ask'\n" + fx + codex))
        #expect(CLI.keptLines(you, file: none) == ["Keeping you answering from blackice mode or the menu; the file says no one."])
        #expect(CLI.keptLines(try ProviderConfiguration.starting(configText: text, after: nil), file: file).isEmpty)
    }

    /// What start says it drops of a switch, before Touch ID: the file changed since the last start,
    /// so it loads the file's own mode and answerer. Until 1.0.8 it said nothing of it.
    @Test func startSaysWhatItDrops() throws {
        let fx = "[[hook]]\non = 'connection'\nprogram = '/opt/fx'\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\ninstructions = 'fx'\n"
        let claude = "[[hook]]\non = 'connection'\nprogram = '/opt/claude'\napp = 'com.anthropic.claude-code'\n" +
            "team = 'Q6L2SF6YDW'\ninstructions = 'claude-code'\n"
        let text = "mode = 'ask'\n" + fx + claude + "[agent]\nanswers = 'claude-code'\n"
        let rule = "\n[[allow]]\napp = 'com.apple.curl'\nhosts = ['pypi.org']\n"
        func dropped(_ held: ProviderConfiguration, _ fileText: String) throws -> [String] {
            let candidate = try ProviderConfiguration.starting(configText: fileText, after: held, keepingSwitches: true)
            #expect(CLI.keptLines(candidate, file: try BlackiceConfig(text: fileText)).isEmpty)
            return CLI.droppedLines(previous: held, candidate: candidate, file: try BlackiceConfig(text: fileText))
        }
        // The menu switched the answers to fx, then a rule was added to the file (approve --save).
        let started = try ProviderConfiguration(generation: 4, mode: .ask, configText: text)
        let toFx = try started.with(mode: .ask, answerer: .agent(.fx))
        #expect(try dropped(toFx, text + rule) == [
            "fx answers now, switched with blackice mode or the menu; blackice.toml has Claude Code, and this start loads it.",
        ])
        // The mode, and both at once.
        #expect(try dropped(try started.with(mode: .acceptAll), text + rule) == [
            "In accept-all mode now, switched with blackice mode or the menu; blackice.toml has ask mode, and this start loads it.",
        ])
        #expect(try dropped(try started.with(mode: .blockAll, answerer: .you), text + rule) == [
            "In block-all mode now, switched with blackice mode or the menu; blackice.toml has ask mode, and this start loads it.",
            "You answer now, switched with blackice mode or the menu; blackice.toml has Claude Code, and this start loads it.",
        ])
        // With a hook of one's own it is the hooks that answer, as status says.
        let own = "mode = 'ask'\n" + fx + claude + "[[hook]]\non = 'connection'\nrun = 'true'\n[agent]\nanswers = 'claude-code'\n"
        #expect(try dropped(try ProviderConfiguration(generation: 2, mode: .ask, configText: own).with(mode: .ask, answerer: .you),
                            own + rule)
            == ["Your hooks answer now, switched with blackice mode or the menu; blackice.toml has Claude Code, and this start loads it."])
        // A file that has you answering, or names no one.
        let you = "mode = 'ask'\n" + fx + claude + "[agent]\nanswers = 'you'\n"
        #expect(try dropped(try ProviderConfiguration(generation: 2, mode: .ask, configText: you)
                .with(mode: .ask, answerer: .agent(.fx)), you + rule)
            == ["fx answers now, switched with blackice mode or the menu; blackice.toml has you answering, and this start loads it."])
        let noOne = "mode = 'ask'\n" + fx + claude
        #expect(try dropped(try ProviderConfiguration(generation: 2, mode: .ask, configText: noOne)
                .with(mode: .ask, answerer: .agent(.fx)), noOne + rule)
            == ["fx answers now, switched with blackice mode or the menu; blackice.toml has fx and Claude Code, each with a hook, " +
                "and this start loads it."])

        // Kept while the file is unchanged, and said as kept.
        let kept = try ProviderConfiguration.starting(configText: text, after: toFx, keepingSwitches: true)
        #expect(CLI.droppedLines(previous: toFx, candidate: kept, file: try BlackiceConfig(text: text)).isEmpty)
        #expect(CLI.keptLines(kept, file: try BlackiceConfig(text: text)).count == 1)
        // Nothing switched, nothing held, or the file changed to what was switched: nothing dropped.
        #expect(try dropped(started, text + rule).isEmpty)
        let first = try ProviderConfiguration.starting(configText: text, after: nil)
        #expect(CLI.droppedLines(previous: nil, candidate: first, file: try BlackiceConfig(text: text)).isEmpty)
        let nowFx = "mode = 'ask'\n" + fx + claude + "[agent]\nanswers = 'fx'\n"
        #expect(try dropped(toFx, nowFx).isEmpty)
    }

    /// `status` says where what blackice holds differs from ~/.config/blackice/blackice.toml: a
    /// switch the file does not have, and a file the next start loads.
    @Test func statusSaysWhereBlackiceDiffersFromTheFile() throws {
        let fx = "[[hook]]\non = 'connection'\nprogram = '/opt/fx'\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\ninstructions = 'fx'\n"
        let claude = "[[hook]]\non = 'connection'\nprogram = '/opt/claude'\napp = 'com.anthropic.claude-code'\n" +
            "team = 'Q6L2SF6YDW'\ninstructions = 'claude-code'\n"
        let text = "mode = 'ask'\n" + fx + claude + "[agent]\nanswers = 'claude-code'\n"
        let changed = text + "\n[[allow]]\napp = 'com.apple.curl'\nhosts = ['pypi.org']\n"
        func status(_ held: ProviderConfiguration, file: String?) -> [String] {
            CLI.statusLines(StatusReport(filter: .on(held), daemonRunning: true,
                                         pending: PendingReply(events: [], approvals: []).deciding(with: held), file: file))
        }
        let started = try ProviderConfiguration(generation: 4, mode: .ask, configText: text)
        #expect(status(started, file: text) == [
            "blackice is on in ask mode",
            "  answers    Claude Code; also connected: fx",
            "  waiting    nothing",
            "  rules      none",
            "  timeout    10 s",
        ])
        // The menu switched the answers to fx: the file still has Claude Code, and the next start keeps fx.
        let toFx = try started.with(mode: .ask, answerer: .agent(.fx))
        #expect(status(toFx, file: text)[1] == "  answers    fx (switched with blackice mode or the menu; blackice.toml has Claude Code)")
        #expect(!status(toFx, file: text).contains { $0.hasPrefix("  file") })
        // Then the file changed: the next start loads it.
        #expect(status(toFx, file: changed) == [
            "blackice is on in ask mode",
            "  answers    fx (switched with blackice mode or the menu; blackice.toml has Claude Code)",
            "  waiting    nothing",
            "  rules      none",
            "  timeout    10 s",
            "  file       changed since the last start: blackice start loads it (Claude Code answers)",
        ])
        // The mode.
        let acceptAll = try started.with(mode: .acceptAll)
        #expect(status(acceptAll, file: text).first
            == "blackice is on in accept-all mode (switched with blackice mode or the menu; blackice.toml has ask)")
        #expect(status(acceptAll, file: changed).last
            == "  file       changed since the last start: blackice start loads it (ask mode, Claude Code answers)")
        // A file changed in its rules alone, one that does not load, and none.
        #expect(status(started, file: changed).last == "  file       changed since the last start: blackice start loads it")
        #expect(status(started, file: "mode = 'sometimes'\n").last
            == "  file       changed since the last start, and blackice start cannot load it: " +
               "blackice validate ~/.config/blackice/blackice.toml")
        #expect(status(toFx, file: nil)[1] == "  answers    fx (switched with blackice mode or the menu)")
        #expect(status(acceptAll, file: nil).first == "blackice is on in accept-all mode (switched with blackice mode or the menu)")
        #expect(status(started, file: nil) == status(started, file: text))
        // The file was changed to what was switched: nothing to say of the switch, and the start loads the file.
        let nowFx = "mode = 'ask'\n" + fx + claude + "[agent]\nanswers = 'fx'\n"
        #expect(status(toFx, file: nowFx)[1] == "  answers    fx; also connected: Claude Code")
        #expect(status(toFx, file: nowFx).last == "  file       changed since the last start: blackice start loads it")
    }

    /// From three hooks in a row with no answer, `status` says since when, how many, when the
    /// latest failed and why, until an hour after the latest.
    @Test func statusSaysThatHooksKeepFailing() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 15 January 2027, 08:00 UTC
        let since = now.addingTimeInterval(-3 * 3600 + 120)
        let last = now.addingTimeInterval(-600)
        let held = try snapshot(.ask, withHook)
        func status(_ failing: FailingHooks?, _ configuration: ProviderConfiguration) -> [String] {
            CLI.statusLines(StatusReport(filter: .on(configuration), daemonRunning: true,
                                         pending: PendingReply(events: [], approvals: []).deciding(with: configuration),
                                         failingHooks: failing), now: now, timeZone: utc)
        }
        let reason = "fx ask: API request failed · HTTP 502 · insufficient_funds"
        #expect(status(FailingHooks(count: 297, since: since, last: last, reason: reason), held).contains(
            "  hooks      failing since 05:02 (297 in a row, the last at 07:50): fx ask: API request failed · HTTP 502 · insufficient_funds"))
        #expect(status(FailingHooks(count: 40, atLeast: true, since: since.addingTimeInterval(-86_400), last: last, reason: nil), held)
            .contains("  hooks      failing since 14 Jan 05:02 or earlier (at least 40 in a row, the last at 07:50)"))
        // What the hook wrote stays on one line, its controls escaped, cut at 100 characters.
        let long = String(repeating: "x", count: 120)
        let line = try #require(status(FailingHooks(count: 3, last: last, reason: "a\u{7}b\u{202E}c " + long), held)
            .first { $0.hasPrefix("  hooks") })
        #expect(line == "  hooks      failing (3 in a row, the last at 07:50): a\\u{7}b\\u{202e}c " + String(repeating: "x", count: 93) + "…")
        // A daemon that started again in the run, and counted from 1, does not shorten it.
        let records = [
            #"{"type":"hooks_failing","count":297,"reason":"exit_status","stderr_line":"\#(reason)","since":"2027-01-15T05:02:00.000Z","ts":"2027-01-15T07:30:00.000Z"}"#,
            #"{"type":"hook_no_answer","event":"ev-00000001","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T07:49:00.000Z"}"#,
            #"{"type":"hook_no_answer","event":"ev-00000002","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T07:49:30.000Z"}"#,
            #"{"type":"hook_no_answer","event":"ev-00000003","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T07:50:00.000Z"}"#,
            #"{"type":"hooks_failing","count":3,"reason":"exit_status","stderr_line":"\#(reason)","since":"2027-01-15T07:49:00.000Z","ts":"2027-01-15T07:50:00.000Z"}"#,
        ]
        let restarted = FailingHooks.parse(Data(("piece\"}\n" + records.joined(separator: "\n") + "\n").utf8), partialFirstLine: true)
        #expect(status(restarted, held).contains(
            "  hooks      failing since 05:02 (300 in a row, the last at 07:50): fx ask: API request failed · HTTP 502 · insufficient_funds"))
        // An hour after the latest, or with no time for it, nothing: it may have been switched or mended since.
        #expect(!status(FailingHooks(count: 297, since: since, last: now.addingTimeInterval(-3600), reason: reason), held)
            .contains { $0.hasPrefix("  hooks") })
        #expect(!status(FailingHooks(count: 297, since: since, reason: reason), held).contains { $0.hasPrefix("  hooks") })
        // No hook runs outside ask mode, or with no hook: nothing to say.
        #expect(!status(FailingHooks(count: 5, last: last), try snapshot(.blockAll, withHook)).contains { $0.hasPrefix("  hooks") })
        #expect(!status(FailingHooks(count: 5, last: last), try snapshot(.ask)).contains { $0.hasPrefix("  hooks") })
        #expect(!status(nil, held).contains { $0.hasPrefix("  hooks") })
    }

    /// An upgrade's start that turned the filter off and stopped part way turns it back on, and
    /// says so; status no longer puts a filter left off down to System Settings alone; and mode
    /// refuses, before Touch ID, what no filter would take.
    @Test func aRequestMacOSCouldNotAuthorizeSaysWhereToRunIt() {
        #expect(CLI.extensionRefusalHint(domain: "OSSystemExtensionErrorDomain", code: 13)
            == "macOS needs an administrator to confirm this and could not ask: run the command in a terminal on the Mac itself, " +
            "not over ssh.")
        #expect(CLI.extensionRefusalHint(domain: "OSSystemExtensionErrorDomain", code: 4) == nil)
        #expect(CLI.extensionRefusalHint(domain: "NSCocoaErrorDomain", code: 13) == nil)
    }

    @Test func whatIsSaidOfAFilterLeftOff() throws {
        #expect(CLI.statusLines(StatusReport(filter: .disabled, daemonRunning: false, pending: nil))
            == ["blackice is off: its filter is turned off (in System Settings, or by a blackice start that did not finish). " +
                "blackice start turns it on."])
        #expect(CLI.putBackLines(interrupted: true, on: true) == [
            "blackice start was stopped before it finished, so it turned blackice's filter back on with the configuration it had. " +
                "Run blackice start again.",
        ])
        #expect(CLI.putBackLines(interrupted: false, on: false) == [
            "blackice start did not finish, and could not turn blackice's filter back on: blackice is off, and no connection " +
                "is checked. Run blackice start again.",
        ])
        // Stopped before it turned the filter off, by a signal agent connect caught during Touch ID.
        #expect(CLI.stoppedBeforeTurnOffLine == "blackice start was stopped before it changed anything: " +
            "blackice's filter is on as it was. Run blackice start again to finish the upgrade.")
        func notAsked() -> UnfinishedUpgrade? {
            Issue.record("asked about the upgrade")
            return nil
        }
        #expect(CLI.modeRefusal(enabled: false, unchanged: false, upgrade: notAsked()) == CLI.turnedOffLine)
        #expect(CLI.modeRefusal(enabled: false, unchanged: true, upgrade: notAsked()) == CLI.turnedOffLine)
        // Worded for agent connect and the menu as well as blackice mode, which all change the mode.
        #expect(CLI.modeRefusal(enabled: true, unchanged: false, upgrade: UnfinishedUpgrade(app: "16", running: ["15"]))
            == "blackice was upgraded to build 16, but macOS still runs build 15's network extension. " +
               "blackice start finishes the upgrade. Run it, then try again.")
        #expect(CLI.modeRefusal(enabled: true, unchanged: false, upgrade: nil) == nil)
        // Already in that mode: said as such, with no question to macOS and no refusal.
        #expect(CLI.modeRefusal(enabled: true, unchanged: true, upgrade: notAsked()) == nil)
    }

    /// An upgrade's start, stopped while it waits with the filter off, waits on at the first
    /// Control-C and says so once, and stops waiting at the second: a filter turned on at the first
    /// would be held with the one the kernel is still disconnecting.
    @Test func anUpgradeStoppedOnceWaitsAndTwiceStops() {
        let kernel = "Waiting for macOS to let the old filter go before turning blackice back on; " +
            "press Control-C again to turn it on now."
        let request = "Waiting for macOS to finish replacing blackice's network extension before turning blackice back on; " +
            "press Control-C again to turn it on now."
        #expect(CLI.waitingAfterInterruptLine(.kernel) == kernel)
        #expect(CLI.waitingAfterInterruptLine(.request) == request)

        var duringKernel = UpgradeInterruption()
        #expect([0, 0, 1, 1, 1, 2, 3].map { duringKernel.action(.kernel, interrupts: $0) }
            == [.wait, .wait, .tell(kernel), .wait, .wait, .stop, .stop])
        // Said once a start, whichever wait came first.
        #expect(duringKernel.action(.request, interrupts: 1) == .wait)

        var duringRequest = UpgradeInterruption()
        #expect([0, 1, 1, 2].map { duringRequest.action(.request, interrupts: $0) } == [.wait, .tell(request), .wait, .stop])
        // Two at once, as from a terminal and a closed session together: nothing more to wait for.
        var both = UpgradeInterruption()
        #expect(both.action(.kernel, interrupts: 2) == .stop)

        var said: [String] = []
        var asked = UpgradeInterruption()
        #expect([0, 1, 1, 2].map { asked.stopWaiting(.kernel, interrupts: $0, say: { said.append($0) }) }
            == [false, false, false, true])
        #expect(said == [kernel])
    }

    /// SIGTERM stops the wait at once, whether it is the first signal or comes after a closed
    /// terminal's: launchd, a supervisor or kill(1) sends it, often with SIGKILL a few seconds
    /// later, and a start killed while it waits would leave the filter saved off.
    @Test func anUpgradeStoppedBySIGTERMStopsWaiting() {
        var first = UpgradeInterruption()
        #expect(first.action(.kernel, interrupts: 1, terminated: true) == .stop)
        var duringRequest = UpgradeInterruption()
        #expect(duringRequest.action(.request, interrupts: 1, terminated: true) == .stop)
        // A hang-up first, told about, then SIGTERM, which counts no further.
        var later = UpgradeInterruption()
        #expect(later.action(.kernel, interrupts: 1) == .tell(CLI.waitingAfterInterruptLine(.kernel)))
        #expect(later.action(.kernel, interrupts: 1) == .wait)
        #expect(later.action(.request, interrupts: 1, terminated: true) == .stop)
        var said: [String] = []
        var asked = UpgradeInterruption()
        let stopped = asked.stopWaiting(.kernel, interrupts: 1, terminated: true, say: { said.append($0) })
        #expect(stopped && said.isEmpty)
    }

    @Test func modeAndFirstStartHints() throws {
        #expect(CLI.modeChangedLines(try snapshot(.blockAll), daemonRunning: false) == ["✓ Now in block-all mode"])
        #expect(CLI.modeChangedLines(try snapshot(.ask), daemonRunning: false) == ["✓ Now in ask mode, you answer: blackice pending"])
        #expect(CLI.modeChangedLines(try snapshot(.ask, withHook), daemonRunning: false).last
            == "  The hooks need the daemon, which is not running: blackice agent install")
        #expect(CLI.modeChangedLines(try snapshot(.ask, withHook), daemonRunning: true).count == 1)
        #expect(CLI.alreadyLine(try snapshot(.blockAll)) == "Already in block-all mode.")

        // A start that finished an upgrade loads the daemon Homebrew removed, in any mode; another
        // start leaves it as it is and says so in ask mode. Nothing with the daemon loaded or no hook.
        #expect(CLI.daemonAfterStart(try snapshot(.ask, withHook), upgraded: true, daemonRunning: false) == .load)
        #expect(CLI.daemonAfterStart(try snapshot(.acceptAll, withHook), upgraded: true, daemonRunning: false) == .load)
        #expect(CLI.daemonAfterStart(try snapshot(.ask, withHook), upgraded: false, daemonRunning: false) == .warn)
        #expect(CLI.daemonAfterStart(try snapshot(.acceptAll, withHook), upgraded: false, daemonRunning: false) == .nothing)
        #expect(CLI.daemonAfterStart(try snapshot(.ask, withHook), upgraded: true, daemonRunning: true) == .nothing)
        #expect(CLI.daemonAfterStart(try snapshot(.ask), upgraded: true, daemonRunning: false) == .nothing)

        // Who answers, when there is a choice.
        let fx = "[[hook]]\non = 'connection'\nprogram = '/opt/fx'\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\ninstructions = 'fx'\n"
        let codex = "[[hook]]\non = 'connection'\nprogram = '/opt/codex'\napp = 'codex'\nteam = '2DC432GLL2'\ninstructions = 'codex'\n"
        let two = try ProviderConfiguration(generation: 2, mode: .ask, configText: "mode = 'ask'\n" + fx + codex + "[agent]\nanswers = 'codex'\n")
        #expect(CLI.modeChangedLines(two, daemonRunning: true) == ["✓ Now in ask mode, Codex answers"])
        #expect(CLI.answeringLine(two.config) == "Codex; also connected: fx")
        let you = try BlackiceConfig(text: "mode = 'ask'\n" + fx + codex + "[agent]\nanswers = 'you'\n")
        #expect(CLI.answeringLine(you) == "you, with blackice pending; connected: fx and Codex")
        #expect(CLI.answeringLine(try BlackiceConfig(text: "mode = 'ask'\n" + fx + codex)) == "fx and Codex, each with a hook")
        #expect(CLI.answeringLine(try BlackiceConfig(text: "mode = 'ask'\n" + fx)) == "fx")
        #expect(CLI.modeSummary(try ProviderConfiguration(generation: 2, mode: .ask, configText: "mode = 'ask'\n" + fx + codex))
            == "ask mode, fx and Codex answer")
        #expect(CLI.answererRefusal(.agent(.claudeCode), config: two.config)
            == "Claude Code is not connected. Connect it first: blackice agent connect claude-code")
        #expect(CLI.answererRefusal(.agent(.fx), config: two.config) == nil && CLI.answererRefusal(.you, config: two.config) == nil)

        let first = CLI.firstStartLines(try snapshot(.acceptAll), daemonRunning: false)
        #expect(first.contains("  blackice mode ask          hold what no rule covers until you or an agent answers"))
        #expect(CLI.firstStartLines(try snapshot(.ask, withHook), daemonRunning: false)
            .contains("  blackice agent install     run your hooks"))
        let ask = CLI.firstStartLines(try snapshot(.ask), daemonRunning: false)
        #expect(ask.contains("  blackice agent connect fx  let fx answer"))
        #expect(!CLI.firstStartLines(try snapshot(.ask, withHook), daemonRunning: false).contains { $0.contains("agent connect") })
    }

    @Test func startSaysWhatItDidOnOneLine() throws {
        #expect(CLI.onLines(try snapshot(.blockAll)) == ["✓ blackice is on in block-all mode"])
        #expect(CLI.onLines(try snapshot(.ask)) == ["✓ blackice is on in ask mode, you answer: blackice pending"])
    }

    @Test func approvalStepsFollowTheMacOSVersion() {
        let tahoe = ExtensionApproval.lines(macOS: 27, opened: true, setup: true)
        #expect(tahoe == [
            "",
            "3 · Allow the network extension",
            "  System Settings is open at General › Login Items:",
            "    1. Scroll to Blackice in the list and click ⓘ next to it.",
            "    2. Turn on Network Extension, then click Done.",
            "  Waiting for you (up to 10 minutes)…",
        ])
        #expect(ExtensionApproval.lines(macOS: 26, opened: false, setup: false)[1...2] == [
            "Allow the network extension", "  Open System Settings › General › Login Items:"])
        #expect(ExtensionApproval.lines(macOS: 15, opened: true, setup: true)
            .contains("    1. Under Extensions, click ⓘ next to Network Extensions."))
        #expect(ExtensionApproval.lines(macOS: 14, opened: true, setup: true)
            .contains("  System Settings is open at Privacy & Security:"))
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

    @Test func textAppsChoseIsEscapedForTheTerminal() {
        #expect(Describe.terminalSafe("Slack") == "Slack")
        #expect(Describe.terminalSafe("Café · 日本語 · 👩‍💻") == "Café · 日本語 · 👩‍💻")
        #expect(Describe.terminalSafe("a\u{1B}[31mb") == "a\\u{1b}[31mb")
        #expect(Describe.terminalSafe("a\u{9B}2Kb\u{7F}\u{0}\t\n") == "a\\u{9b}2Kb\\u{7f}\\u{0}\\u{9}\\u{a}")
        // Bidirectional controls reorder what follows; separators break the line.
        #expect(Describe.terminalSafe("tool\u{202E}gpj.exe") == "tool\\u{202e}gpj.exe")
        #expect(Describe.terminalSafe("\u{2066}x\u{2069}\u{200F}\u{061C}\u{2028}\u{2029}")
            == "\\u{2066}x\\u{2069}\\u{200f}\\u{61c}\\u{2028}\\u{2029}")
        // Escaping twice changes nothing more.
        let once = Describe.terminalSafe("a\u{1B}b")
        #expect(Describe.terminalSafe(once) == once)
    }

    @Test func describe() {
        #expect(Describe.count(0, "rule") == "no rules" && Describe.count(1, "rule") == "1 rule" && Describe.count(2, "rule") == "2 rules")
        #expect(Describe.path("/Users/test/.config/blackice/blackice.toml", home: "/Users/test") == "~/.config/blackice/blackice.toml")
        #expect(Describe.path("/Users/tester/x", home: "/Users/test") == "/Users/tester/x")
        #expect(Describe.path("n.toml", home: "/Users/test") == "n.toml")
    }
}
