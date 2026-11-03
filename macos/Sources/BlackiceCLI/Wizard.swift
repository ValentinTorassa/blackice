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

    public init(ask: ((String) -> String?)?, createFile: @escaping (String, Data) throws -> Void,
                identify: @escaping (String) -> SigningIdentity?, fileExists: @escaping (String) -> Bool,
                home: String, version: String?) {
        self.ask = ask
        self.createFile = createFile
        self.identify = identify
        self.fileExists = fileExists
        self.home = home
        self.version = version
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
        return Interaction(
            ask: interactive ? { prompt in
                FileHandle.standardOutput.write(Data(prompt.utf8))
                return readLine(strippingNewline: true)
            } : nil,
            createFile: CLI.createFile,
            identify: CodeIdentity.identity(atPath:),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: NSHomeDirectory(),
            version: version)
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
    }

    static let docs = "https://blackice-macos.vercel.app/docs/configuration"
    static let maximumRules = 32

    let ask: (String) -> String?
    let say: (String) -> Void
    let identify: (String) -> SigningIdentity?
    let fileExists: (String) -> Bool
    let home: String

    /// nil when the input ended (Control-D) before the last answer. Everything is indented under
    /// the step's title, which the caller prints.
    func run() -> Answers? {
        var answers = Answers()
        say("  How should blackice treat new connections?")
        say("")
        say("    1  accept-all  Let everything through and log it. Start here.")
        say("    2  ask         Hold what no rule allows until you or an agent answers.")
        say("    3  block-all   Let through only what your rules allow.")
        say("")
        guard let mode = chooseMode() else { return nil }
        answers.mode = mode
        if mode == .ask {
            say("")
            say("  A connection nobody answers in time is denied.")
            guard let seconds = askSeconds() else { return nil }
            answers.timeoutSeconds = seconds
        }
        if mode != .acceptAll {
            say("")
            say("  Apps you trust can connect in every mode. Name one by its path")
            say("  (/Applications/Slack.app, /usr/bin/curl) or its signing identifier.")
            say("  Press Enter on an empty line when you are done.")
            say("")
            while answers.rules.count < Self.maximumRules {
                guard let line = ask("  App: ") else { return nil }
                let input = line.trimmingCharacters(in: .whitespaces)
                if input.isEmpty { break }
                guard let identity = resolveApp(input) else { continue }
                guard let hosts = askHosts(identity) else { return nil }
                if hosts.isEmpty { say("    Skipped \(identity.signingID)."); continue }
                answers.rules.append(Rule(identity: identity, hosts: hosts))
                say("    " + Style.done("\(identity.signingID) may reach \(hosts == ["*"] ? "any host" : hosts.joined(separator: ", "))"))
            }
        }
        if mode == .ask {
            say("")
            say("  To have an agent such as fx answer for you, add a hook later:")
            say("  \(Self.docs)")
        }
        return answers
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
            guard let line = ask("  Seconds to wait for an answer [60]: ") else { return nil }
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
            say("    \(path) is \(Self.describe(identity))")
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
            "# blackice configuration, written by blackice init.",
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
