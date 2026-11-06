import Foundation
import BlackiceCore

/// What the commands need from the person at the terminal, passed in so tests can answer.
public struct Interaction {
    /// Prints a prompt and reads one line; nil at the end of input. nil when no one is at a terminal.
    public let ask: ((String) -> String?)?
    /// Creates a new file, with its folder; never replaces one.
    public let createFile: (String, Data) throws -> Void
    /// The rule identity of the app or binary at a path; see `CodeIdentity.identity(atPath:)`.
    public let identify: (String) -> SigningIdentity?
    public let fileExists: (String) -> Bool
    public let home: String
    /// "0.2.0 (build 6)", from Blackice.app's Info.plist; nil for a build outside the app.
    public let version: String?
    /// Shows a list to pick from with the arrow keys; nil when the terminal cannot, and then the
    /// questions are typed. Returns the picked indices, or nil when the person cancelled.
    public let choose: ((Choice) -> [Int]?)?
    /// The apps running now, as paths to their .app bundles in /Applications or ~/Applications,
    /// and the system extensions running now, as their bundles in /Library/SystemExtensions.
    public let runningApps: () -> [String]
    /// The network extensions macOS has activated and enabled, running or not, as their bundles in
    /// /Library/SystemExtensions. A VPN client's runs only while the VPN is on.
    public let networkExtensions: () -> [String]

    public init(ask: ((String) -> String?)?, createFile: @escaping (String, Data) throws -> Void,
                identify: @escaping (String) -> SigningIdentity?, fileExists: @escaping (String) -> Bool,
                home: String, version: String?, choose: ((Choice) -> [Int]?)? = nil,
                runningApps: @escaping () -> [String] = { [] }, networkExtensions: @escaping () -> [String] = { [] }) {
        self.ask = ask
        self.createFile = createFile
        self.identify = identify
        self.fileExists = fileExists
        self.home = home
        self.version = version
        self.choose = choose
        self.runningApps = runningApps
        self.networkExtensions = networkExtensions
    }

    /// No terminal: nothing is asked and nothing is written.
    public static var none: Interaction {
        Interaction(ask: nil, createFile: { path, _ in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) },
                    identify: { _ in nil }, fileExists: { _ in false }, home: NSHomeDirectory(), version: nil)
    }

    /// The real terminal, when standard input and output are both one.
    public static func terminal() -> Interaction {
        let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        let info = Bundle.main.infoDictionary
        var version: String?
        if let short = info?["CFBundleShortVersionString"] as? String {
            version = (info?["CFBundleVersion"] as? String).map { "\(short) (build \($0))" } ?? short
        }
        var ask: ((String) -> String?)?
        var choose: ((Choice) -> [Int]?)?
        if interactive {
            // Ends the line early, as nil, once a signal is caught (`Interrupts`).
            ask = { prompt in
                try? FileHandle.standardOutput.write(contentsOf: Data(prompt.utf8))
                return Interrupts.readLine()
            }
            if ProcessInfo.processInfo.environment["TERM"] != "dumb" { choose = { TerminalSelector.run($0) } }
        }
        let home = NSHomeDirectory()
        return Interaction(ask: ask, createFile: CLI.createFile, identify: CodeIdentity.identity(atPath:),
                           fileExists: { FileManager.default.fileExists(atPath: $0) }, home: home, version: version,
                           choose: choose, runningApps: { runningAppBundles(home: home) },
                           networkExtensions: { activatedNetworkExtensionBundles() })
    }

    /// The .app bundles in /Applications and ~/Applications that have a process running, by the
    /// outermost bundle in each process's path (a helper counts for its app), and the running
    /// system extensions' bundles. Blackice and its filter are left out.
    static func runningAppBundles(home: String) -> [String] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var bundles = Set<String>()
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let bundle = appBundle(path, home: home) { bundles.insert(bundle) }
        }
        return bundles.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    /// "/Applications/Slack.app" for any path inside it; nil outside the two Applications folders.
    /// A system extension that is running, such as a VPN client's network extension, counts by its
    /// .systemextension bundle in /Library/SystemExtensions: on 3 November 2026 Tailscale's sent
    /// most of the events in ask mode, and it runs from there, not from its app.
    static func appBundle(_ path: String, home: String) -> String? {
        if path.hasPrefix(systemExtensions), let end = path.range(of: ".systemextension/") {
            let bundle = String(path[..<end.lowerBound]) + ".systemextension"
            return bundle.hasSuffix("/com.valentorassa.blackice.filter.systemextension") ? nil : bundle
        }
        let folders = ["/Applications/", home + "/Applications/"]
        guard folders.contains(where: { path.hasPrefix($0) }), let end = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<end.lowerBound]) + ".app"
        return bundle == "/Applications/Blackice.app" ? nil : bundle
    }

    static let systemExtensions = "/Library/SystemExtensions/"

    /// "Slack" for "/Applications/Slack.app". A system extension's bundle is named by its
    /// identifier, so its name is the one its Info.plist gives ("Tailscale Network Extension").
    static func appName(_ bundle: String) -> String {
        let file = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        guard bundle.hasSuffix(".systemextension"),
              let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") else { return file }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String, !name.isEmpty, name != file { return name }
        }
        return file
    }

    /// A system extension as `systemextensionsctl list` names it.
    struct ListedExtension: Equatable {
        let teamID: String
        let bundleID: String
        /// "Tailscale Network Extension".
        let name: String
    }

    static let networkExtensionCategory = "com.apple.system_extension.network_extension"

    /// The network extensions `systemextensionsctl list` shows as activated and enabled, in its
    /// order. Its rows are tab-separated (enabled, active, Team ID, "bundle ID (version)", name,
    /// "[state]"), under a "--- category" line for each kind of extension. Left out: blackice's own
    /// filter, the other kinds (a camera extension), the other states (one waiting for the person
    /// in System Settings, one turned off there, one left until a restart uninstalls it), and a row
    /// with no Team ID or with a bundle ID a path could not hold.
    static func activatedNetworkExtensions(_ listing: String) -> [ListedExtension] {
        var category = ""
        var listed: [ListedExtension] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("--- ") {
                category = String(line.dropFirst(4).prefix { $0 != " " })
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard category == networkExtensionCategory, fields.count >= 6,
                  fields[fields.count - 1].trimmingCharacters(in: .whitespaces) == "[activated enabled]" else { continue }
            let team = String(fields[2])
            let bundleID = String(fields[3].prefix { $0 != " " })
            guard validTeamID(team), validSigningID(bundleID), bundleID != BlackiceIdentifiers.filter else { continue }
            listed.append(ListedExtension(teamID: team, bundleID: bundleID,
                                          name: fields[4..<(fields.count - 1)].joined(separator: "\t")))
        }
        return listed
    }

    /// Each extension's bundle: `<bundle ID>.systemextension` in one of the folders macOS makes for
    /// extensions in /Library/SystemExtensions, `folders` being their names. One upgraded in place
    /// keeps its old folder until the Mac restarts; both have the same signing identifier and team,
    /// so the first one found is taken. An extension with no bundle there is left out.
    static func extensionBundles(_ extensions: [ListedExtension], folders: [String],
                                 fileExists: (String) -> Bool) -> [String] {
        let folders = folders.sorted()
        return extensions.compactMap { item in
            folders.lazy.map { systemExtensions + $0 + "/" + item.bundleID + ".systemextension" }.first(where: fileExists)
        }
    }

    /// The bundles of the network extensions macOS has activated and enabled, by their names; none
    /// when `systemextensionsctl` cannot be run.
    static func activatedNetworkExtensionBundles() -> [String] {
        let listed = activatedNetworkExtensions(systemExtensionList())
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !listed.isEmpty, let folders = try? FileManager.default.contentsOfDirectory(atPath: systemExtensions) else {
            return []
        }
        return extensionBundles(listed, folders: folders, fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// What `systemextensionsctl list` prints, which needs no administrator; empty when it fails.
    static func systemExtensionList() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: output, as: UTF8.self) : ""
    }
}

/// `blackice init`, and `blackice start` when there is no blackice.toml yet: a few questions,
/// then a commented file that parses.
struct ConfigWizard {
    struct Rule: Equatable {
        let identity: SigningIdentity
        let hosts: [String]
    }

    struct Answers: Equatable {
        var mode: Mode = .acceptAll
        var timeoutSeconds = 60
        var rules: [Rule] = []
        /// The agent to connect right after the first start (`blackice agent connect`), if any.
        var agent: String?
    }

    static let docs = "https://blackice-macos.vercel.app/docs/configuration"
    static let maximumRules = 32

    let ask: (String) -> String?
    let say: (String) -> Void
    let identify: (String) -> SigningIdentity?
    let fileExists: (String) -> Bool
    let home: String
    /// The arrow-key list; nil, and every answer is typed.
    var choose: ((Choice) -> [Int]?)? = nil
    var runningApps: () -> [String] = { [] }
    var networkExtensions: () -> [String] = { [] }

    /// nil when the input ended (Control-D) before the last answer. Everything is indented under
    /// the step's title, which the caller prints.
    func run() -> Answers? {
        if let choose { return picked(choose) }
        var answers = Answers()
        say("  How should blackice treat new connections?")
        say("    1  accept-all  Let everything through and log it. Start here.")
        say("    2  ask         Hold what no rule allows until you or an agent answers.")
        say("    3  block-all   Let through only what your rules allow.")
        guard let mode = chooseMode() else { return nil }
        answers.mode = mode
        if mode == .ask {
            guard let seconds = askSeconds() else { return nil }
            answers.timeoutSeconds = seconds
        }
        if mode != .acceptAll {
            say("  Apps to trust in every mode, one per line: a path (/Applications/Slack.app)")
            say("  or a signing identifier (com.apple.curl). An empty line ends the list.")
            guard let rules = typedRules(from: []) else { return nil }
            answers.rules = rules
        }
        if mode == .ask {
            say("  An agent can answer for you: blackice agent connect fx or claude-code")
        }
        return answers
    }

    /// Apps typed one per line, each with its hosts, after `rules`; nil when the input ended.
    private func typedRules(from rules: [Rule]) -> [Rule]? {
        var rules = rules
        while rules.count < Self.maximumRules {
            guard let line = ask("  App: ") else { return nil }
            let input = line.trimmingCharacters(in: .whitespaces)
            if input.isEmpty { break }
            guard let identity = resolveApp(input) else { continue }
            guard let hosts = askHosts(identity) else { return nil }
            if hosts.isEmpty { say("    Skipped \(identity.signingID)."); continue }
            rules.append(Rule(identity: identity, hosts: hosts))
            say("    " + Style.done("\(identity.signingID) may reach \(hosts == ["*"] ? "any host" : hosts.joined(separator: ", "))") +
                " (\(identity.teamID.map { "team \($0)" } ?? "signed by Apple"))")
        }
        return rules
    }

    static let modes: [(Mode, String)] = [
        (.acceptAll, "accept-all   Let everything through and log it"),
        (.ask, "ask          Hold what no rule allows until an agent or you answer"),
        (.blockAll, "block-all    Let through only what your rules allow"),
    ]

    /// The same questions as lists to pick from: the mode, who answers in ask mode, and the apps
    /// to trust, from the ones running now. Nothing to type unless the person picks "another app".
    private func picked(_ choose: (Choice) -> [Int]?) -> Answers? {
        var answers = Answers()
        guard let mode = choose(Choice(options: Self.modes.map(\.1), multiple: false,
                                       prompt: "  How should blackice treat new connections?",
                                       labels: Self.modes.map(\.0.rawValue)))?.first else { return nil }
        answers.mode = Self.modes[mode].0
        if answers.mode == .ask {
            // Codex and opencode are not offered here for now (AgentInstructions.listedBeforeConnecting);
            // `blackice agent connect codex|opencode` sets them up.
            let agents = [("fx", "fx", "fx: blackice installs it if needed and signs it in"),
                          ("claude-code", "Claude Code", "Claude Code: blackice installs it if needed and signs it in"),
                          ("codex", "Codex", "Codex, with your ChatGPT plan, once installed"),
                          ("opencode", "opencode", "opencode, with a provider you pick")]
                .filter { AgentInstructions(rawValue: $0.0)?.listedBeforeConnecting ?? true }
            let options = agents.map(\.2) + ["Me, with blackice pending, approve and deny"]
            guard let who = choose(Choice(options: options, multiple: false, prompt: "  Who answers the connections that wait?",
                                          labels: agents.map(\.1) + ["you"]))?.first else { return nil }
            answers.agent = who < agents.count ? agents[who].0 : nil
        }
        if answers.mode != .acceptAll {
            guard let rules = pickApps(choose) else { return nil }
            answers.rules = rules
        }
        return answers
    }

    /// Apps to trust, each to reach any host: first the network extensions macOS has activated,
    /// ticked, then the apps running now. A VPN client's extension carries its tunnel, and often the
    /// Mac's DNS lookups: with no rule its connections wait in ask mode and are dropped in block-all,
    /// and on 3 November 2026 Tailscale's sent most of the events in ask mode. The person can untick
    /// one. "Another app" asks for a path or name and its hosts, as the typed questions do.
    private func pickApps(_ choose: (Choice) -> [Int]?) -> [Rule]? {
        var seen = Set<SigningIdentity>()
        // Each app named its own bundle, so the name is escaped, in the list and in what follows.
        func listed(_ paths: [String]) -> [(name: String, identity: SigningIdentity)] {
            paths.compactMap { path in
                guard let identity = identify(path), seen.insert(identity).inserted else { return nil }
                return (Describe.terminalSafe(Interaction.appName(path)), identity)
            }
        }
        let extensions = listed(networkExtensions())
        let apps = Array((extensions + listed(runningApps())).prefix(Self.maximumRules))
        let other = "Another app: type its path or name"
        guard let picks = choose(Choice(options: apps.map(\.name) + [other], multiple: true,
                                        initial: Array(apps.indices.prefix(extensions.count)),
                                        prompt: "  Which apps may connect anywhere, in every mode?",
                                        labels: apps.map(\.name) + ["another app"])) else { return nil }
        var rules: [Rule] = []
        for index in picks where index < apps.count {
            rules.append(Rule(identity: apps[index].identity, hosts: ["*"]))
        }
        guard picks.contains(apps.count) else { return rules }
        say("  Other apps: a path or signing identifier per line, then an empty line.")
        return typedRules(from: rules)
    }

    private func chooseMode() -> Mode? {
        while true {
            guard let line = ask("  Mode [1]: ") else { return nil }
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "1", "accept-all": return .acceptAll
            case "2", "ask": return .ask
            case "3", "block-all": return .blockAll
            default: say("    Type 1, 2 or 3.")
            }
        }
    }

    private func askSeconds() -> Int? {
        let range = BlackiceConfig.timeoutRange
        while true {
            guard let line = ask("  Seconds to wait for an answer before denying [60]: ") else { return nil }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return 60 }
            if let seconds = Int(text), range.contains(seconds) { return seconds }
            say("    A whole number from \(range.lowerBound) to \(range.upperBound).")
        }
    }

    /// A path (or an app's name in /Applications) is read from its signature; anything else is a
    /// signing identifier, and then the Team ID is asked.
    private func resolveApp(_ input: String) -> SigningIdentity? {
        var path: String?
        if input.contains("/") || input.hasSuffix(".app") {
            path = input.hasPrefix("~/") ? home + input.dropFirst(1) : input
        } else if !input.contains(".") {
            // Signing identifiers are reverse DNS names; a bare word is an app's name.
            guard fileExists("/Applications/\(input).app") else {
                say("    There is no /Applications/\(input).app. Give the app's path, or its")
                say("    signing identifier (such as com.apple.curl).")
                return nil
            }
            path = "/Applications/\(input).app"
        }
        if let path {
            guard fileExists(path) else { say("    There is nothing at \(path)."); return nil }
            guard let identity = identify(path) else {
                say("    \(path) is unsigned or ad hoc signed, so a rule cannot name it.")
                say("    In ask mode you can approve it when it connects instead.")
                return nil
            }
            return identity
        }
        guard validSigningID(input) else {
            say("    That is neither a path nor a signing identifier (such as com.apple.curl).")
            return nil
        }
        while true {
            guard let line = ask("    Its Team ID (Enter if it is Apple's own): ") else { return nil }
            let team = line.trimmingCharacters(in: .whitespaces)
            if team.isEmpty { return SigningIdentity(signingID: input, teamID: nil) }
            if validTeamID(team) { return SigningIdentity(signingID: input, teamID: team) }
            say("    A Team ID is 10 capital letters or digits; codesign -dv shows it.")
        }
    }

    /// "com.apple.curl, signed by Apple", "com.tinyspeck.slackmacgap, team BQR82RBBHL".
    static func describe(_ identity: SigningIdentity) -> String {
        identity.signingID + (identity.teamID.map { ", team \($0)" } ?? ", signed by Apple")
    }

    /// The hosts for one rule: names, or `*` alone for any host. Empty skips the app; nil when the
    /// input ended.
    private func askHosts(_ identity: SigningIdentity) -> [String]? {
        while true {
            guard let line = ask("    Hosts it may reach, separated by spaces (* for any): ") else { return nil }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            if words.isEmpty { return [] }
            if words == ["*"] { return ["*"] }
            if words.contains("*") { say("    * stands alone: it means any host."); continue }
            var hosts: [String] = []
            var bad: String?
            for word in words {
                guard let host = normalizeHost(word) else { bad = word; break }
                if !hosts.contains(host) { hosts.append(host) }
            }
            if let bad {
                say("    \(bad.prefix(64)) is not a host name. Use names such as api.example.com,")
                say("    without https://.")
                continue
            }
            guard hosts.count <= BlackiceConfig.maximumHostsPerRule else {
                say("    At most \(BlackiceConfig.maximumHostsPerRule) hosts per app."); continue
            }
            return hosts
        }
    }

    /// The file `blackice init` writes, with comments that say how to go on.
    static func render(_ answers: Answers) -> String {
        var lines = [
            "# blackice configuration, written by blackice.",
            "# Change it any time, then load it with: blackice start",
            "# Every key: \(docs)",
            "",
            commented("mode = \"\(answers.mode.rawValue)\"", "accept-all, ask or block-all"),
            commented("timeout_seconds = \(answers.timeoutSeconds)", "in ask mode, no answer in time means deny"),
            "",
        ]
        if answers.rules.isEmpty {
            lines += [
                "# Let an app reach some hosts in every mode. It is named by its signing identifier, and",
                "# its Team ID unless it is Apple's own; codesign -dv shows both.",
                "# [[allow]]",
                "# app = \"com.apple.curl\"",
                "# hosts = [\"pypi.org\"]",
            ]
        } else {
            lines.append("# Apps that may reach these hosts in every mode.")
            for rule in answers.rules {
                lines.append("[[allow]]")
                lines.append("app = \"\(rule.identity.signingID)\"")
                if let team = rule.identity.teamID { lines.append("team = \"\(team)\"") }
                lines.append("hosts = [\(rule.hosts.map { "\"\($0)\"" }.joined(separator: ", "))]")
                lines.append("")
            }
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A key and a comment, the comments lined up.
    private static func commented(_ line: String, _ comment: String) -> String {
        line.padding(toLength: max(line.count + 1, 24), withPad: " ", startingAt: 0) + "# " + comment
    }
}
