import Foundation
import BlackiceCore

// `blackice agent connect NAME`: sets a coding agent up to answer the connections that wait in
// ask mode, the way integrations/fx/README.md describes by hand. The steps are the same for every
// agent: find it and read its signature; give it a home of its own with the blackice skill and
// rules that let it run only `blackice approve` and `blackice deny`; let it decide one sample
// event through the hook runner, with blackice replaced by a stand-in; add a rule that lets it
// reach its model in every mode, and the hook; load it. What differs between agents (where its
// settings live, how it signs in, its hook line) is in its `AgentProfile`. fx is the first.

/// What blackice needs to know about one coding agent.
public struct AgentProfile: Sendable {
    /// The name on the command line: `blackice agent connect fx`.
    public let name: String
    /// Its executable's name, looked up on PATH.
    public let executable: String
    /// What it needs to reach for its model and sign-in. blackice.toml allows these in every
    /// mode, bound to the agent's signature, or the agent would wait on its own approval.
    public let hosts: [String]
    /// Inside the agent home: the folder its skills are read from, and its settings file.
    let skillsFolder: String
    let settingsFile: String
    /// The skill's folder under Blackice.app's Resources/agents.
    let resource: String
    /// Where to get it, when it is not installed.
    let installHint: String
    /// What signing in looks like, said before its login runs.
    let loginHint: [String]
    /// What it runs with in its home, on top of the hook's environment.
    let environment: @Sendable (_ agentHome: String) -> [String: String]
    let statusArguments: [String]
    let loginArguments: [String]
    /// Whether the status command's output says it is signed in.
    let signedIn: @Sendable (_ statusOutput: String) -> Bool
    /// Its settings file, with the rules set and its other keys kept.
    let settings: @Sendable (_ existing: Data?) throws -> Data
    /// The hook's run line, with blackice (or the test's stand-in) from `blackiceDirectory`.
    let hookRun: @Sendable (_ executable: String, _ agentHome: String, _ blackiceDirectory: String) -> String

    public static let fx = AgentProfile(
        name: "fx", executable: "fx", hosts: ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"],
        skillsFolder: ".fx/skills", settingsFile: ".fx/settings.json", resource: "fx/blackice",
        installHint: "https://github.com/vercel-labs/fx",
        loginHint: ["fx prints a link: open it, allow access, and come back here."],
        // fx v0.0.16 reads HOME, not FX_HOME; with its keychain off its sign-in is a file in that home.
        environment: { ["HOME": $0, "FX_DISABLE_KEYCHAIN": "1"] },
        statusArguments: ["status"], loginArguments: ["login", "vercel"],
        signedIn: { CLI.fxSignedIn($0) }, settings: { try CLI.fxSettings($0) },
        hookRun: { CLI.fxHookRun(fx: $0, agentHome: $1, blackiceDirectory: $2) })

    public static let known = [fx]

    /// What the hook asks the agent. A hook whose line holds it already uses the blackice skill.
    public static let prompt = "Use the blackice skill to decide whether to approve the pending connection"
}

/// The home that agents get for answering blackice, and what is in it for one agent.
struct AgentPaths {
    let home: String
    let profile: AgentProfile

    init(userHome: String, profile: AgentProfile) {
        home = userHome + "/.config/blackice/agent"
        self.profile = profile
    }

    var skills: String { home + "/" + profile.skillsFolder }
    var skill: String { skills + "/blackice" }
    var settings: String { home + "/" + profile.settingsFile }
    var test: String { home + "/test" }
    /// The folders to create, outermost first.
    var folders: [String] {
        var folders = [home]
        var path = home
        for part in profile.skillsFolder.split(separator: "/") {
            path += "/" + part
            folders.append(path)
        }
        return folders
    }
}

/// What connecting an agent needs from the Mac, passed in so tests can fake it.
public struct AgentMachine {
    /// The first executable with this name on PATH or in the usual install folders.
    public let findExecutable: (String) -> String?
    /// Runs a program with this terminal attached, for a sign-in; its exit status.
    public let runAttached: (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Int32
    /// Runs a program and returns its exit status and output.
    public let runCaptured: (_ path: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)
    /// Runs one hook line for an event the way the daemon does (HookRunner).
    public let runHook: (_ run: String, _ event: HookEvent, _ workDirectory: String, _ timeoutSeconds: Int) -> HookResult
    /// The folder inside Blackice.app with each agent's skill (agents/fx/blackice); nil outside the app.
    public let agentResources: String?

    public init(findExecutable: @escaping (String) -> String?,
                runAttached: @escaping (String, [String], [String: String]) -> Int32,
                runCaptured: @escaping (String, [String], [String: String]) -> (status: Int32, output: String),
                runHook: @escaping (String, HookEvent, String, Int) -> HookResult,
                agentResources: String?) {
        self.findExecutable = findExecutable
        self.runAttached = runAttached
        self.runCaptured = runCaptured
        self.runHook = runHook
        self.agentResources = agentResources
    }

    /// Nothing found, nothing run.
    public static var none: AgentMachine {
        AgentMachine(findExecutable: { _ in nil }, runAttached: { _, _, _ in 127 }, runCaptured: { _, _, _ in (127, "") },
                     runHook: { _, _, _, _ in HookResult(hookLine: 0, outcome: .failedToStart("no hook runner"), stderr: "",
                                                         stderrTruncated: false, duration: 0) },
                     agentResources: nil)
    }

    /// This Mac: PATH and the usual folders, Process, HookRunner, and Blackice.app's resources.
    public static func real() -> AgentMachine {
        AgentMachine(
            findExecutable: { name in
                let home = NSHomeDirectory()
                let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
                let folders = path.split(separator: ":").map(String.init)
                    + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin"]
                for folder in folders where folder.hasPrefix("/") {
                    let candidate = folder + "/" + name
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                       FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
                return nil
            },
            runAttached: { path, arguments, environment in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                do { try process.run() } catch { return 127 }
                process.waitUntilExit()
                return process.terminationStatus
            },
            runCaptured: { path, arguments, environment in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return (127, "\(error)") }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            },
            runHook: { run, event, workDirectory, timeoutSeconds in
                let failed = { (why: String) in
                    HookResult(hookLine: 0, outcome: .failedToStart(why), stderr: "", stderrTruncated: false, duration: 0)
                }
                do {
                    let runner = try HookRunner(options: .init(workDirectory: URL(fileURLWithPath: workDirectory),
                                                               environment: HookRunner.environment(for: try UserAccount.current())))
                    let box = ResultBox()
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        box.results = await runner.run([Hook(run: run, line: 0)], for: event, timeoutSeconds: timeoutSeconds)
                        done.signal()
                    }
                    done.wait()
                    return box.results.first ?? failed("the hook runner returned nothing")
                } catch {
                    return failed("\(error)")
                }
            },
            agentResources: Bundle.main.resourceURL.map { $0.appendingPathComponent("agents").path }
                .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil })
    }
}

private final class ResultBox: @unchecked Sendable {
    var results: [HookResult] = []
}

/// What the stand-in for blackice recorded during the test.
enum TestAnswer: Equatable {
    case approved, denied
    /// The agent ran nothing.
    case none
    /// More than one answer, or one without the event's token.
    case wrong(String)
}

extension CLI {
    static let appBinDirectory = "/Applications/Blackice.app/Contents/MacOS"
    static let hookPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// fx's hook line: fx in its own home, with blackice (or the test's stand-in) first on PATH.
    /// The paths sit in double quotes inside a single-quoted TOML string; see `fitsHookLine`.
    static func fxHookRun(fx: String, agentHome: String, blackiceDirectory: String = appBinDirectory) -> String {
        "FX_DISABLE_KEYCHAIN=1 PATH=\"\(blackiceDirectory):\(hookPath)\" HOME=\"\(agentHome)\" \"\(fx)\" " +
            "ask --no-save --no-color \"\(AgentProfile.prompt)\""
    }

    /// A path that can go inside the hook line as it is: absolute, with no quote, $, backquote,
    /// backslash or control character.
    static func fitsHookLine(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { "\"'$`\\".unicodeScalars.contains($0) || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// fx's settings in the agent home, with the rules of integrations/fx/README.md: ask mode, the
    /// shell limited to blackice approve and deny, no edits and no web. Other keys are kept.
    static func fxSettings(_ existing: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw ConfigError(line: nil, "is not a JSON object")
            }
            object = parsed
        }
        object["permission_mode"] = "ask"
        object["permission"] = [
            "bash": ["*": "deny", "blackice approve *": "allow", "blackice deny *": "allow"],
            "edit": ["*": "deny"],
            "web_fetch": ["*": "deny"],
            "web_search": ["*": "deny"],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// `fx status` prints `[status] auth=missing` until fx is signed in.
    static func fxSignedIn(_ status: String) -> Bool {
        for line in status.split(whereSeparator: \.isNewline) where line.hasPrefix("[status] auth=") {
            let value = line.dropFirst("[status] auth=".count).trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value != "missing"
        }
        return false
    }

    /// The stand-in writes one line per call, its arguments as the shell passed them.
    static func testAnswer(_ recorded: String, token: String) -> TestAnswer {
        let calls = recorded.split(whereSeparator: \.isNewline).map(String.init)
        guard !calls.isEmpty else { return .none }
        guard calls.count == 1 else { return .wrong("answered \(calls.count) times") }
        let words = calls[0].split(separator: " ").map(String.init)
        guard let index = words.firstIndex(of: "--token"), index + 1 < words.count, words[index + 1] == token else {
            return .wrong("answered without the event's token")
        }
        switch words.first {
        case "approve": return .approved
        case "deny": return .denied
        default: return .wrong("ran blackice \(words.first ?? "")")
        }
    }

    /// The rule and hook to add to blackice.toml; empty when both are there already.
    static func agentAddition(_ name: String, identity: SigningIdentity, hosts: [String], run: String?) -> String {
        guard !hosts.isEmpty || run != nil else { return "" }
        var lines = ["", "# \(name) answers the connections that wait in ask mode (added by blackice agent connect \(name))."]
        if !hosts.isEmpty {
            lines += ["[[allow]]", "app = \"\(identity.signingID)\""]
            if let team = identity.teamID { lines.append("team = \"\(team)\"") }
            lines.append("hosts = [" + hosts.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        }
        if let run {
            if !hosts.isEmpty { lines.append("") }
            lines += ["[[hook]]", "on = \"connection\"", "run = '\(run)'"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The text with a root key set to a new value, keeping its comment; the key is added at the
    /// top when it is not there. Only keys before the first table count.
    static func settingRootKey(_ text: String, _ key: String, to value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let rest = trimmed[trimmed.index(after: equals)...]
            var comment = ""
            if let hash = rest.firstIndex(of: "#") { comment = "    " + rest[hash...] }
            let setting = "\(key) = \(value)"
            lines[index] = comment.isEmpty ? setting
                : setting.padding(toLength: max(setting.count + 1, 24), withPad: " ", startingAt: 0) + comment.drop(while: { $0 == " " })
            return lines.joined(separator: "\n")
        }
        let insertAt = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") } ?? lines.count
        lines.insert("\(key) = \(value)", at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// The sample event fx decides in the test: an app it should approve. The token and the
    /// deadline are fresh.
    static func sampleAgentEvent(now: Date = Date()) throws -> HookEvent {
        try HookEvent.connection(
            app: HookEvent.App(signingID: "com.microsoft.VSCode", teamID: "UBF8T346G9",
                               path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            host: "update.code.visualstudio.com", ip: "13.107.246.40", port: 443,
            deadline: now.addingTimeInterval(TimeInterval(agentTestSeconds)))
    }

    static let agentTestSeconds = 120

    // MARK: - The command

    static func connectAgent(_ name: String, configPath: String?, readFile: (String) throws -> Data,
                             system: SystemControlling, interaction: Interaction, machine: AgentMachine,
                             stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void) -> Int32 {
        guard let profile = AgentProfile.known.first(where: { $0.name == name }) else {
            stderr("blackice agent connect knows fx so far (Claude Code and Codex are planned): blackice agent connect fx")
            return ExitCode.usage
        }
        let name = profile.name
        guard let ask = interaction.ask else {
            stderr("blackice agent connect asks questions and signs \(profile.name) in, so it needs a terminal.")
            return ExitCode.usage
        }
        let path = configPath ?? defaultConfigPath
        let shown = Describe.path(path, home: interaction.home)
        let text: String
        let config: BlackiceConfig
        switch loadConfig(path, readFile: readFile, stderr: stderr, shown: shown, hint: false) {
        case .failure(let status):
            if status.code == ExitCode.unreadable, isMissing(path, readFile: readFile) {
                stderr("Set blackice up first, then connect \(name): blackice start" + (configPath == nil ? "" : " --config \(shown)"))
            }
            return status.code
        case .success(let loaded):
            text = loaded.text
            config = loaded.config
        }
        func step(_ title: String) { stdout(""); stdout(Style.heading(title)); stdout("") }
        func fail(_ status: Int32, _ lines: String...) -> Int32 { lines.forEach { stderr("  " + $0) }; return status }

        stdout("Connecting \(name) to blackice: it will answer the connections that wait in")
        stdout("ask mode, with nobody at the keyboard.")

        // 1. Find it and read its signature.
        step("1 · Find \(name)")
        guard let executable = machine.findExecutable(profile.executable) else {
            return fail(ExitCode.unavailable, "\(name) is not installed. Install it (\(profile.installHint)), then run",
                        "this again.")
        }
        let shownExecutable = Describe.path(executable, home: interaction.home)
        guard fitsHookLine(executable) else {
            return fail(ExitCode.unavailable,
                        "\(shownExecutable) has a quote, $ or backslash in its path, which a hook line cannot hold.")
        }
        guard let identity = interaction.identify((executable as NSString).resolvingSymlinksInPath) else {
            return fail(ExitCode.unavailable, "\(shownExecutable) is unsigned or ad hoc signed, so a rule cannot name it.")
        }
        stdout("  " + Style.done("\(shownExecutable) is \(ConfigWizard.describe(identity))"))

        // 2. Its own home: the skill, a sign-in, and the rules.
        step("2 · Give \(name) a home of its own")
        let paths = AgentPaths(userHome: interaction.home, profile: profile)
        let homeShown = Describe.path(paths.home, home: interaction.home)
        guard fitsHookLine(paths.home) else {
            return fail(ExitCode.unavailable, "\(homeShown) has a quote, $ or backslash in its path, which a hook line cannot hold.")
        }
        guard let resources = machine.agentResources else {
            return fail(ExitCode.unavailable, "This blackice has no agent skills inside it. Use the blackice command from Blackice.app.")
        }
        let files = FileManager.default
        do {
            let parent = (paths.home as NSString).deletingLastPathComponent
            if !files.fileExists(atPath: parent) {
                try files.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for folder in paths.folders { try privateFolder(folder) }
            if files.fileExists(atPath: paths.skill) { try files.removeItem(atPath: paths.skill) }
            try files.copyItem(atPath: resources + "/" + profile.resource, toPath: paths.skill)
        } catch {
            return fail(ExitCode.cannotCreate, "Cannot set up \(homeShown): \(describe(error))")
        }
        stdout("  " + Style.done("The blackice skill is in \(homeShown)"))
        let environment = profile.environment(paths.home)
        func signedIn() -> Bool { profile.signedIn(machine.runCaptured(executable, profile.statusArguments, environment).output) }
        if signedIn() {
            stdout("  " + Style.done("\(name) is signed in there"))
        } else {
            stdout("  Sign \(name) in for blackice.")
            profile.loginHint.forEach { stdout("  " + $0) }
            stdout("")
            _ = machine.runAttached(executable, profile.loginArguments, environment)
            stdout("")
            guard signedIn() else {
                return fail(ExitCode.software, "\(name) is still not signed in, so nothing else changed. Run this again to retry.")
            }
            stdout("  " + Style.done("\(name) is signed in"))
        }
        do {
            let settings = try profile.settings(files.contents(atPath: paths.settings))
            try writeAtomically(settings, to: paths.settings, mode: 0o600)
        } catch {
            return fail(ExitCode.cannotCreate, "Cannot write \(Describe.path(paths.settings, home: interaction.home)): \(describe(error))")
        }
        stdout("  " + Style.done("There, \(name) may run blackice approve and blackice deny, and nothing else"))

        // 3. One sample event through the hook runner, with a stand-in for blackice.
        step("3 · Try it on a sample connection")
        let event: HookEvent
        let standIn = paths.test + "/bin"
        do {
            if files.fileExists(atPath: paths.test) { try files.removeItem(atPath: paths.test) }
            try PrivateDirectory.ensure(URL(fileURLWithPath: paths.test))
            try PrivateDirectory.ensure(URL(fileURLWithPath: standIn))
            let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$(dirname \"$0\")/answers\"\necho 'ok (blackice agent connect test)'\n"
            try writeAtomically(Data(script.utf8), to: standIn + "/blackice", mode: 0o700)
            event = try sampleAgentEvent()
        } catch {
            return fail(ExitCode.cannotCreate, "Cannot set up the test in \(homeShown): \(describe(error))")
        }
        defer { try? files.removeItem(atPath: paths.test) }
        stdout("  \(name) is deciding whether Visual Studio Code may reach")
        stdout("  update.code.visualstudio.com. blackice is a stand-in for this test, so")
        stdout("  nothing is let through…")
        let result = machine.runHook(profile.hookRun(executable, paths.home, standIn), event,
                                     paths.test + "/work", agentTestSeconds)
        let recorded = files.contents(atPath: standIn + "/answers").map { String(decoding: $0, as: UTF8.self) } ?? ""
        let seconds = Int(result.duration.rounded())
        switch testAnswer(recorded, token: event.token) {
        case .approved:
            stdout("  " + Style.done("\(name) approved it in \(seconds) s"))
        case .denied:
            stdout("  " + Style.done("\(name) answered in \(seconds) s (it denied it; any answer shows the wiring works)"))
        case .none, .wrong:
            let why: String
            switch testAnswer(recorded, token: event.token) {
            case .wrong(let reason): why = "\(name) \(reason)"
            default:
                switch result.outcome {
                case .timedOut: why = "\(name) gave no answer in \(agentTestSeconds) s"
                case .exited(let status): why = "\(name) exited with status \(status) and gave no answer"
                case .failedToStart(let reason): why = "\(name) did not start: \(reason)"
                case .signaled(let signal): why = "\(name) died from signal \(signal)"
                case .dropped(let reason): why = "the hook did not run (\(reason.rawValue))"
                }
            }
            stderr("  \(why), so blackice.toml was left as it was.")
            let tail = result.stderr.split(whereSeparator: \.isNewline).suffix(8)
            if !tail.isEmpty {
                stderr("  \(name)'s last lines:")
                tail.forEach { stderr("    " + $0.prefix(200)) }
            }
            stderr("  If blackice is in ask or block-all mode, \(name)'s own connections wait too: switch to")
            stderr("  accept-all (blackice mode accept-all) and run this again.")
            return ExitCode.software
        }

        // 4. The rule for its model, the hook, and time enough to answer.
        step("4 · Add \(name) to \(shown)")
        let missing = profile.hosts.filter { config.allowRule(for: identity, host: $0) == nil }
        let existingHook = config.hooks.first { $0.run.contains(AgentProfile.prompt) }
        var updated = text
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += agentAddition(name, identity: identity, hosts: missing,
                                 run: existingHook == nil ? profile.hookRun(executable, paths.home, appBinDirectory) : nil)
        // Three times what the test took, in whole tens: 21 s on the test Mac asks for 70.
        let neededSeconds = max(60, (seconds * 3 + 9) / 10 * 10)
        var raisedTimeout = false
        if config.timeoutSeconds < neededSeconds, config.timeoutSeconds < BlackiceConfig.timeoutRange.upperBound {
            updated = settingRootKey(updated, "timeout_seconds", to: "\(min(neededSeconds, BlackiceConfig.timeoutRange.upperBound))")
            raisedTimeout = true
        }
        if missing.isEmpty {
            stdout("  \(name) could already reach its model's hosts.")
        } else {
            stdout("  " + Style.done("A rule lets \(name) reach its model in every mode:"))
            stdout("    " + listed(missing))
        }
        if let existingHook {
            stdout("  A hook already runs the blackice skill (line \(existingHook.line)); it stays as it is.")
        } else {
            stdout("  " + Style.done("A hook runs \(name) for each connection that waits"))
        }
        if raisedTimeout {
            stdout("  " + Style.done("timeout_seconds is now \(min(neededSeconds, BlackiceConfig.timeoutRange.upperBound)), " +
                                     "so \(name) has time to answer"))
        }
        guard let saved = save(updated, over: text, at: path, shown: shown, stdout: stdout, stderr: stderr) else {
            return ExitCode.cannotCreate
        }
        var loaded = saved

        // 5. Load it, in ask mode if the person wants, and make sure the daemon runs.
        step("5 · Turn it on")
        var mode = config.mode
        if mode != .ask {
            stdout("  In ask mode, a connection no rule covers waits until \(name) answers (\(seconds) s on")
            stdout("  the test); with no answer in time it is denied.")
            while true {
                guard let line = ask("  Switch to ask mode now? [y/N]: ") else { return ExitCode.success }
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                if ["y", "yes"].contains(answer) {
                    guard let switched = save(settingRootKey(loaded, "mode", to: "\"ask\""), over: loaded, at: path,
                                              shown: shown, stdout: stdout, stderr: stderr) else { return ExitCode.cannotCreate }
                    loaded = switched
                    mode = .ask
                    break
                }
                if ["", "n", "no"].contains(answer) { break }
                stdout("    Type y or n.")
            }
        }
        stdout("")
        let started = system.start(configText: loaded, output: SystemOutput(stdout: stdout, stderr: stderr))
        guard started == ExitCode.success else { return started }
        stdout("")
        let daemon = system.installAgent(output: SystemOutput(stdout: stdout, stderr: stderr))
        guard daemon == ExitCode.success else { return daemon }
        stdout("")
        if mode == .ask {
            stdout(Style.done("\(name) answers what no rule covers. See what waits with: ") + Style.command("blackice pending"))
        } else {
            stdout(Style.done("\(name) is ready. When you want it answering: ") + Style.command("blackice mode ask"))
        }
        return ExitCode.success
    }

    /// A folder of the agent home, made private: created with mode 0700, or, when it is already
    /// this user's own directory (not a symlink) with group or other bits, set to 0700. Anything
    /// else (a symlink, another owner) is refused by `PrivateDirectory.ensure`.
    static func privateFolder(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) != 0 {
            guard chmod(path, 0o700) == 0 else { throw FileSafetyError(path, "cannot set mode 0700") }
        }
        try PrivateDirectory.ensure(URL(fileURLWithPath: path))
    }

    /// blackice's own errors say what is wrong in their description; Foundation's, in localizedDescription.
    static func describe(_ error: Error) -> String {
        (error as? FileSafetyError)?.description ?? error.localizedDescription
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Writes the new text if it parses, keeping the file's mode; the text written, or nil.
    private static func save(_ text: String, over previous: String, at path: String, shown: String,
                             stdout: (String) -> Void, stderr: (String) -> Void) -> String? {
        guard text != previous else { return text }
        do {
            _ = try BlackiceConfig(data: Data(text.utf8))
        } catch {
            stderr("  blackice agent connect: the file it would write does not parse (\(error)); nothing was written")
            return nil
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        do {
            try writeAtomically(Data(text.utf8), to: path, mode: mode_t(mode))
        } catch {
            stderr("  Cannot write \(shown): \(error.localizedDescription)")
            return nil
        }
        stdout("    Saved \(shown)")
        return text
    }

    /// Replaces a file through a temporary file in the same folder.
    static func writeAtomically(_ data: Data, to path: String, mode: mode_t) throws {
        let folder = (path as NSString).deletingLastPathComponent
        let temporary = folder + "/.\((path as NSString).lastPathComponent).\(getpid()).tmp"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard fchmodat(AT_FDCWD, temporary, mode, 0) == 0, rename(temporary, path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }
}
