import Foundation
import BlackiceCore

// `blackice agent connect NAME`: sets a coding agent up to answer the connections that wait in
// ask mode, the way integrations/fx/README.md describes by hand. The steps are the same for every
// agent: find it and read its signature; give it a home of its own, with its sign-in and, for fx,
// rules that let it read files and nothing else, no shell included; let it decide one sample
// event through the hook runner, reading its answer from its last line of output and passing it
// nowhere; add a rule that lets it reach its model in every mode, and a hook that starts it
// directly, checks its signature first and names its instructions; load it. The instructions
// come from blackice itself: the daemon writes them into each event's directory (see
// AgentInstructions), so nothing in the agent's home says how to decide. What differs between
// agents (where its settings live, how it signs in, its arguments) is in its `AgentProfile`. fx
// is the first. Claude Code (claude-code) has no settings file: its limits are its arguments.
// opencode decides with a provider chosen when it is connected, and the rule names that
// provider's hosts. Each connected agent keeps its hook, and `answers` in [agent] names the one
// that answers.

/// What blackice needs to know about one coding agent.
public struct AgentProfile: Sendable {
    /// The name on the command line: `blackice agent connect fx`.
    public let name: String
    /// Its executable's name, looked up on PATH.
    public let executable: String
    /// What it needs to reach for its model and sign-in. blackice.toml allows these in every
    /// mode, bound to the agent's signature, or the agent would wait on its own approval.
    public let hosts: [String]
    /// Inside the agent home: its own folder, and its settings file, when blackice writes one.
    let folder: String
    let settingsFile: String?
    /// What the daemon writes into each event's directory for it (`instructions` in its hook).
    let instructions: AgentInstructions
    /// The model its hook asks for unless `--model` names another: a small one, since each
    /// decision is a short read and a two-line answer.
    public let defaultModel: String
    /// Where to get it, when it is not installed.
    let installHint: String
    /// Its own installer, as a shell command line, offered when it is not installed.
    let installer: String?
    /// What signing in looks like, said before its login runs.
    let loginHint: [String]
    /// What it runs with in its home, on top of the hook's environment: for its sign-in, its
    /// status and the hook's `env`.
    let environment: @Sendable (_ agentHome: String) -> [String: String]
    let statusArguments: [String]
    let loginArguments: [String]
    /// Whether the status command's output says it is signed in.
    let signedIn: @Sendable (_ statusOutput: String) -> Bool
    /// Its settings file, with the rules set and its other keys kept; nil with no settings file.
    let settings: (@Sendable (_ existing: Data?) throws -> Data)?
    /// The hook's `args`: one request to this model that ends with the answer as its last line of
    /// output.
    let askArguments: @Sendable (_ agentHome: String, _ model: String) -> [String]
    /// What to do about a failure the agent's output names, when the test gets no answer.
    var advice: @Sendable (_ output: String) -> [String] = { _ in [] }
    /// Text that only this agent's hook holds in its `args`, for hooks written before they named
    /// their instructions: a hook with it is this agent's.
    var hookMarker = AgentProfile.prompt
    /// What keeps it to deciding, said once its home is ready, when it has no settings file.
    var limits: String?
    /// Whether its hook gets the event on stdin (`stdin = "none"` in blackice.toml when not).
    var eventOnStdin = true
    /// The environment that makes `installer` put it in this folder and change nothing else, for
    /// when the copy on PATH cannot be named by a rule (a development build, unsigned or ad hoc
    /// signed); nil when its installer cannot do that.
    var privateInstall: (@Sendable (_ folder: String) -> [String: String])?
    /// Folders in the home, besides the usual ones, where its installer puts it.
    var installFolders: [String] = []
    /// The providers it can decide with, when it asks which one; empty for an agent that has one.
    var providers: [AgentProvider] = []
    /// This agent with that provider: its hosts, model and sign-in.
    var forProvider: (@Sendable (AgentProvider) -> AgentProfile)?
    /// The provider this profile is for, when it has one.
    var provider: AgentProvider?

    public static let fx = AgentProfile(
        name: "fx", executable: "fx", hosts: ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"],
        folder: ".fx", settingsFile: ".fx/settings.json", instructions: .fx,
        // Paid from AI Gateway credits: on 5 November 2026 `fx models` priced Claude Haiku 5.5 at $0.10 and $0.50
        // per million tokens in and out, a hundredth of Claude Fable 5.1. `--model` overrides fx's settings.
        defaultModel: "anthropic/claude-haiku-5.5",
        installHint: "https://github.com/vercel-labs/fx",
        // fx's README; it puts fx in ~/.local/bin.
        installer: "curl -fsSL https://fx.sh/setup.sh | bash",
        // fx 0.0.16 waits for Enter before it opens the page and starts checking for the answer.
        loginHint: ["fx prints a code. Press Enter to open the page in your browser, allow",
                    "access there, then come back here."],
        // fx v0.0.16 reads HOME, not FX_HOME; with its keychain off its sign-in is a file in that home.
        environment: { ["HOME": $0, "FX_DISABLE_KEYCHAIN": "1"] },
        statusArguments: ["status"], loginArguments: ["login", "vercel"],
        signedIn: { CLI.fxSignedIn($0) }, settings: { try CLI.fxSettings($0) },
        // With stdout not a terminal, fx prints its reply as plain Markdown; the skill, which fx
        // finds in its workspace's skills/ folder, ends it with the answer.
        // --system replaces fx's own system prompt, written for coding, with two sentences: on 5
        // November 2026 that took 3,700 of the 22,000 tokens each decision read.
        askArguments: { _, model in ["ask", "--no-save", "--no-color", "--model", model, "--system", CLI.fxSystemPrompt, prompt] },
        // Seen on 3 November 2026: a Vercel team with no card on file gets HTTP 403 from AI Gateway.
        // Seen on 4 November 2026: a team with no credits left gets HTTP 502, insufficient_funds.
        advice: { stderr in
            if stderr.contains("customer_verification_required") {
                return ["Vercel's AI Gateway needs a card on file for the team fx signed in with. Add one",
                        "in that team's billing settings on vercel.com, then run this again."]
            }
            if stderr.contains("insufficient_funds") {
                return ["Vercel's AI Gateway has no credits left for the team fx signed in with. Add",
                        "credits on that team's AI Gateway page in the Vercel dashboard",
                        "(https://vercel.com/dashboard, then AI Gateway), then run this again."]
            }
            return []
        },
        // fx's setup.sh installs into FX_INSTALL_DIR, and adds that folder to the shell's startup
        // file unless it is on PATH already: with it on PATH, the file stays as it is, and the
        // person's own fx (`fx upgrade --channel dev` builds are ad hoc signed) stays first on PATH.
        privateInstall: { folder in ["FX_INSTALL_DIR": folder, "PATH": folder + ":/usr/bin:/bin:/usr/sbin:/sbin"] })

    /// Claude Code in print mode. Its configuration directory in the agent home holds its own
    /// sign-in, and nothing of yours.
    public static let claudeCode = AgentProfile(
        // api.anthropic.com for the model; platform.claude.com renews the sign-in (Claude Code
        // 2.1.317's OAuth token endpoint). Nothing else was reached in 20 decisions on 4 November 2026.
        name: "claude-code", executable: "claude", hosts: ["api.anthropic.com", "platform.claude.com"],
        folder: ".claude", settingsFile: nil, instructions: .claudeCode,
        // Counted against the subscription it signs in with; haiku uses the least of it.
        defaultModel: "haiku",
        installHint: "https://code.claude.com/docs/en/setup",
        // Anthropic's native installer; it puts claude in ~/.local/bin.
        installer: "curl -fsSL https://claude.ai/install.sh | bash",
        loginHint: ["Claude Code opens a sign-in page in your browser. Sign in with the account whose",
                    "usage its decisions should count against, then come back here."],
        // HOME stays the account's own: Claude Code keeps its sign-in in the login keychain, and
        // macOS finds that keychain through HOME. The keychain item is named after
        // CLAUDE_CONFIG_DIR, so this sign-in is apart from yours. No telemetry, error reports or
        // update checks, so its rule needs two hosts.
        environment: { ["CLAUDE_CONFIG_DIR": CLI.claudeCodeConfigDirectory(agentHome: $0),
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"] },
        statusArguments: ["auth", "status", "--json"], loginArguments: ["auth", "login"],
        signedIn: { CLI.claudeCodeSignedIn($0) }, settings: nil,
        askArguments: { _, model in CLI.claudeCodeArguments(model: model) },
        // A hook gets none of the shell's variables, so a sign-in through ANTHROPIC_API_KEY, which
        // `claude auth status` counts, is not there. Claude Code says so on stdout.
        advice: { output in
            output.contains("Not logged in")
                ? ["Claude Code had no sign-in in the hook's environment, which has none of your shell's",
                   "variables (ANTHROPIC_API_KEY among them). Sign it in for blackice with:",
                   "CLAUDE_CONFIG_DIR=~/.config/blackice/agent/.claude claude auth login"]
                : []
        },
        hookMarker: CLI.claudeCodePrompt,
        limits: "Its hook gives it one tool, reading the event: no shell, no web, no MCP servers",
        // claude -p adds what comes on stdin to its prompt. The event reaches it only through the
        // Read tool, as data.
        eventOnStdin: false)

    /// Codex (`codex exec`), signed in with a ChatGPT plan. CODEX_HOME in the agent home holds its
    /// own sign-in, apart from yours in ~/.codex.
    public static let codex = AgentProfile(
        // chatgpt.com for the model (its backend API) with a ChatGPT sign-in; auth.openai.com renews
        // that sign-in. On 5 November 2026 Codex 0.166.0 reached only chatgpt.com in its decisions.
        name: "codex", executable: "codex", hosts: ["chatgpt.com", "auth.openai.com"],
        folder: ".codex", settingsFile: nil, instructions: .codex,
        // "Fast and affordable model for easier tasks", in Codex 0.166.0's list; it counts against the plan.
        defaultModel: "gpt-6-luna",
        installHint: "brew install --cask codex, or https://developers.openai.com/codex/cli",
        installer: nil,
        loginHint: ["Codex opens a sign-in page in your browser. Sign in with the ChatGPT account whose",
                    "plan its decisions should count against, then come back here."],
        // HOME stays the account's own, as the daemon sets it; CODEX_HOME keeps the sign-in apart.
        environment: { ["CODEX_HOME": CLI.codexHome(agentHome: $0)] },
        statusArguments: ["login", "status"], loginArguments: ["login"],
        signedIn: { CLI.codexSignedIn($0) }, settings: nil,
        askArguments: { _, model in CLI.codexArguments(model: model) },
        // With no sign-in in CODEX_HOME, Codex 0.166.0 tries api.openai.com and stops at HTTP 401.
        advice: { output in
            output.contains("401 Unauthorized")
                ? ["Codex had no sign-in in the hook's environment, which has none of your shell's",
                   "variables (OPENAI_API_KEY among them). Sign it in for blackice with:",
                   "CODEX_HOME=~/.config/blackice/agent/.codex codex login"]
                : []
        },
        hookMarker: CLI.codexPrompt,
        limits: "Its hook lets it read only the event's directory: no writes, no network, no web search, no MCP servers",
        // codex exec adds what comes on stdin to its prompt. The event reaches it only as a file.
        eventOnStdin: false)

    /// opencode with the first provider in its list; `agent connect opencode` asks which one.
    public static let opencode = openCode(AgentProvider.openCode[0])

    /// opencode (`opencode run`) with one provider. Its HOME is its own folder in the agent home,
    /// where it keeps that provider's sign-in, apart from yours in ~/.local/share/opencode.
    static func openCode(_ provider: AgentProvider) -> AgentProfile {
        AgentProfile(
            name: "opencode", executable: "opencode", hosts: provider.hosts,
            folder: ".opencode", settingsFile: nil, instructions: .opencode,
            defaultModel: provider.id + "/" + provider.model,
            installHint: "https://opencode.ai/docs",
            // opencode's own installer; it puts opencode in ~/.opencode/bin.
            installer: "curl -fsSL https://opencode.ai/install | bash",
            loginHint: ["opencode signs in to \(provider.title): it asks for an API key, or opens a sign-in",
                        "page in your browser. Use the account whose plan its decisions should count",
                        "against, then come back here."],
            environment: { CLI.openCodeEnvironment(agentHome: $0) },
            statusArguments: ["auth", "list", "--standalone", "--format", "json"],
            loginArguments: ["auth", "login", "--standalone", provider.id],
            signedIn: { CLI.openCodeSignedIn($0, provider: provider.id) }, settings: nil,
            askArguments: { _, model in CLI.openCodeArguments(model: model) },
            // With no sign-in for the provider, opencode 2.2.5 says the model is unavailable; with a
            // key the provider refuses, it prints the provider's own error ("token expired or incorrect").
            advice: { output in
                output.contains("Model unavailable") || output.contains("No authenticated integrations")
                    ? ["opencode had no sign-in for \(provider.title) in the hook's environment, which has none",
                       "of your shell's variables (API keys among them). Sign it in for blackice with:",
                       "HOME=~/.config/blackice/agent/.opencode opencode auth login --standalone \(provider.id)"]
                    : []
            },
            hookMarker: CLI.openCodePrompt,
            limits: "Its hook lets it read the event's directory and nothing else: no shell, no edits, no web, no MCP servers",
            // opencode run adds what comes on stdin to its message. The event reaches it only as a file.
            eventOnStdin: false,
            installFolders: [".opencode/bin"],
            providers: AgentProvider.openCode, forProvider: { openCode($0) }, provider: provider)
    }

    public static let known = [fx, claudeCode, codex, opencode]

    /// What the hook asks the agent. A hook whose line holds it already uses the blackice skill.
    public static let prompt = "Use the blackice skill to decide whether to approve the pending connection"
}

/// A provider an agent can decide with, and what blackice lets the agent reach for it.
public struct AgentProvider: Equatable, Sendable {
    /// The agent's name for it: `opencode auth login ID`, and `ID/model` in `--model`.
    public let id: String
    /// What the list shows.
    public let title: String
    public let hosts: [String]
    /// A small model of its own, the part of `--model` after the first slash.
    public let model: String

    /// What opencode can decide with. On 5 November 2026, opencode 2.2.5 decided one event with
    /// each of these, its model fetch off and a key that was not one, through a proxy that logged
    /// what it reached: each reached only its host here, and stopped at the provider's refusal.
    /// OpenAI's are three: api.openai.com for an API key, which that run reached, and, for a
    /// ChatGPT sign-in, chatgpt.com (opencode 2.2.5 holds its backend-api/codex address) and
    /// auth.openai.com, where the sign-in is renewed. Later that day, decisions with a ChatGPT sign-in
    /// reached chatgpt.com only; the renewal at auth.openai.com has not been seen.
    /// The models are the plans' small ones: the coding plans' are included, the others cost $0.10
    /// and $0.50 per million tokens in and out in models.dev's list that day. OpenAI comes first: in
    /// the eval that day gpt-6-luna with a ChatGPT sign-in decided the 23 cases as expected in 3.9 s
    /// at the median, while Z.AI's glm-5.3-flash took 12.8 s and approved Slack on port 6667.
    public static let openCode = [
        AgentProvider(id: "openai", title: "OpenAI, a ChatGPT plan or an API key",
                      hosts: ["chatgpt.com", "auth.openai.com", "api.openai.com"], model: "gpt-6-luna"),
        AgentProvider(id: "zai-coding-plan", title: "Z.AI Coding Plan", hosts: ["api.z.ai"], model: "glm-5.3-flash"),
        AgentProvider(id: "opencode-go", title: "OpenCode Go", hosts: ["opencode.ai"], model: "gpt-6-luna"),
        AgentProvider(id: "minimax-coding-plan", title: "MiniMax Token Plan", hosts: ["api.minimax.io"],
                      model: "MiniMax-M3.1-Flash"),
        AgentProvider(id: "openrouter", title: "OpenRouter", hosts: ["openrouter.ai"], model: "openai/gpt-6-luna"),
        AgentProvider(id: "anthropic", title: "Anthropic, an API key", hosts: ["api.anthropic.com"], model: "claude-haiku-5-5"),
    ]
}

/// The home that agents get for answering blackice, and what is in it for one agent.
struct AgentPaths {
    let home: String
    let profile: AgentProfile

    init(userHome: String, profile: AgentProfile) {
        home = userHome + "/.config/blackice/agent"
        self.profile = profile
    }

    var settings: String? { profile.settingsFile.map { home + "/" + $0 } }
    /// Where blackice installs the agent for itself when the copy on PATH is not signed.
    var bin: String { home + "/bin" }
    var test: String { home + "/test" }
    /// The folders to create, outermost first.
    var folders: [String] {
        var folders = [home]
        var path = home
        for part in profile.folder.split(separator: "/") {
            path += "/" + part
            folders.append(path)
        }
        return folders
    }

    /// The copies of the instructions that `agent connect` put in the home up to 0.4.0, for fx and
    /// Claude Code. Removed once a configuration whose hook names its instructions is loaded.
    var oldCopies: [String] { [home + "/.fx/skills/blackice", home + "/.claude/blackice"] }
}

/// What connecting an agent needs from the Mac, passed in so tests can fake it.
public struct AgentMachine {
    /// The executables with this name on PATH, in the usual install folders and then in the
    /// folders given, in that order, each file once.
    public let findExecutables: (_ name: String, _ alsoIn: [String]) -> [String]
    /// Runs a program with this terminal attached, for a sign-in; its exit status.
    public let runAttached: (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Int32
    /// Runs a program and returns its exit status and output.
    public let runCaptured: (_ path: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)
    /// Runs one hook for an event the way the daemon does (HookRunner), signature check,
    /// instructions and the owner's notes included.
    public let runHook: (_ hook: Hook, _ event: HookEvent, _ notes: String?, _ workDirectory: String,
                         _ timeoutSeconds: Int) -> HookResult
    /// From now on Control-C and the other stop signals are caught instead of ending blackice
    /// (`Interrupts`); the function returned puts back what was there.
    public let catchInterrupts: () -> () -> Void
    /// Whether one of them came since.
    public let interrupted: () -> Bool

    public init(findExecutables: @escaping (String, [String]) -> [String],
                runAttached: @escaping (String, [String], [String: String]) -> Int32,
                runCaptured: @escaping (String, [String], [String: String]) -> (status: Int32, output: String),
                runHook: @escaping (Hook, HookEvent, String?, String, Int) -> HookResult,
                catchInterrupts: @escaping () -> () -> Void = { {} },
                interrupted: @escaping () -> Bool = { false }) {
        self.findExecutables = findExecutables
        self.runAttached = runAttached
        self.runCaptured = runCaptured
        self.runHook = runHook
        self.catchInterrupts = catchInterrupts
        self.interrupted = interrupted
    }

    /// Nothing found, nothing run.
    public static var none: AgentMachine {
        AgentMachine(findExecutables: { _, _ in [] }, runAttached: { _, _, _ in 127 }, runCaptured: { _, _, _ in (127, "") },
                     runHook: { _, _, _, _, _ in HookResult(hookLine: 0, outcome: .failedToStart("no hook runner"), stderr: "",
                                                            stderrTruncated: false, duration: 0) })
    }

    /// This Mac: PATH and the usual folders, Process and HookRunner.
    public static func real() -> AgentMachine {
        AgentMachine(
            findExecutables: { name, alsoIn in
                let home = NSHomeDirectory()
                let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
                let folders = path.split(separator: ":").map(String.init)
                    + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin"] + alsoIn
                var found: [String] = [], files = Set<String>()
                for folder in folders where folder.hasPrefix("/") {
                    let candidate = folder + "/" + name
                    var isDirectory: ObjCBool = false
                    // A symlink counts as the file it leads to: ~/.local/bin/claude is one into
                    // ~/.local/share/claude/versions.
                    if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                       FileManager.default.isExecutableFile(atPath: candidate),
                       files.insert((candidate as NSString).resolvingSymlinksInPath).inserted {
                        found.append(candidate)
                    }
                }
                return found
            },
            runAttached: Self.runAttached,
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
            runHook: { hook, event, notes, workDirectory, timeoutSeconds in
                let failed = { (why: String) in
                    HookResult(hookLine: 0, outcome: .failedToStart(why), stderr: "", stderrTruncated: false, duration: 0)
                }
                do {
                    let runner = try HookRunner(options: .init(workDirectory: URL(fileURLWithPath: workDirectory),
                                                               environment: HookRunner.environment(for: try UserAccount.current())))
                    let box = ResultBox()
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        box.results = await runner.run([hook], for: event, timeoutSeconds: timeoutSeconds, notes: notes) {
                            if case .started(_, let pid, _) = $0 { box.started(pid) }
                        }
                        done.signal()
                    }
                    // The hook runs in a process group of its own, which Control-C from the terminal
                    // does not reach: once blackice catches it, the hook's group gets SIGTERM.
                    var stopped = false
                    while done.wait(timeout: .now() + 0.2) == .timedOut {
                        if !stopped, Interrupts.interrupted, let pid = box.pid {
                            killpg(pid, SIGTERM)
                            stopped = true
                        }
                    }
                    return box.results.first ?? failed("the hook runner returned nothing")
                } catch {
                    return failed("\(error)")
                }
            },
            catchInterrupts: Interrupts.catchAll, interrupted: { Interrupts.interrupted })
    }

    /// Runs a program with this terminal attached and returns its exit status, or 128 plus the
    /// signal that ended it. Not Process: it starts the child in a process group of its own, which
    /// the terminal treats as background, so the child stops (SIGTTIN) at its first read. fx's
    /// sign-in waits for Enter and froze that way on 3 November 2026. posix_spawn without
    /// POSIX_SPAWN_SETPGROUP keeps it in blackice's group, in the foreground.
    ///
    /// As system(3) does, blackice does not die of Control-C or Control-\ while the program runs:
    /// it catches them (`Interrupts`), and the program gets them from the terminal. A SIGTERM or
    /// SIGHUP sent to blackice is passed on to the program. When it ends, the terminal's settings
    /// are put back as they were, in case it died in raw mode.
    static func runAttached(_ path: String, _ arguments: [String], _ environment: [String: String]) -> Int32 {
        let variables = ProcessInfo.processInfo.environment.merging(environment) { $1 }.map { "\($0)=\($1)" }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = variables.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var terminal = termios()
        let isTerminal = tcgetattr(STDIN_FILENO, &terminal) == 0
        let release = Interrupts.catchAll()
        defer { release() }
        // No signal blocked in the program, whatever the calling thread blocks.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK))
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, &attributes, argv, envp) == 0 else { return 127 }
        var status: Int32 = 0
        var passedOn = false
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result == -1, errno != EINTR { return 127 }
            if !passedOn, [SIGTERM, SIGHUP].contains(Interrupts.caught) {
                kill(pid, SIGTERM)
                passedOn = true
            }
            usleep(50_000)
        }
        if isTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &terminal) }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    var results: [HookResult] = []
    private var startedPID: Int32?

    func started(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        startedPID = pid
    }

    var pid: Int32? {
        lock.lock(); defer { lock.unlock() }
        return startedPID
    }
}

/// What the agent answered in the test, or why it did not.
enum TestAnswer: Equatable {
    case answered(HookAnswer)
    /// Why there is no answer, as the end of a sentence that starts with the agent's name.
    case none(String)
}

extension CLI {
    /// The agent's hook: its executable, started directly with its home in `env`, the signature it
    /// must have, read from the executable when it was connected, and its instructions.
    static func agentHook(_ profile: AgentProfile, executable: String, agentHome: String,
                          identity: SigningIdentity, model: String) -> HookProgram {
        HookProgram(path: executable, arguments: profile.askArguments(agentHome, model), environment: profile.environment(agentHome),
                    identity: identity, eventOnStdin: profile.eventOnStdin, instructions: profile.instructions)
    }

    /// The provider an agent decides with: the one `--model PROVIDER/MODEL` names, or the one picked
    /// from the list (with the arrow keys, or typed by number). nil, said why on stderr, when
    /// `--model` names none of them or the input ended.
    static func chooseProvider(_ profile: AgentProfile, model: String?, choose: ((Choice) -> [Int]?)?,
                               ask: (String) -> String?, stdout: (String) -> Void, stderr: (String) -> Void) -> AgentProvider? {
        let providers = profile.providers
        if let model {
            let id = model.split(separator: "/", maxSplits: 1).first.map(String.init) ?? model
            guard model.contains("/"), let provider = providers.first(where: { $0.id == id }) else {
                stderr("agent connect: \(profile.name)'s --model is PROVIDER/MODEL, such as \(profile.defaultModel), with one of")
                stderr("these providers, whose hosts blackice knows: \(listed(providers.map(\.id)))")
                return nil
            }
            return provider
        }
        stdout("")
        stdout("  Which provider should \(profile.name) decide with? Its rule lets it reach that")
        stdout("  provider's hosts and nothing else, and you sign it in to that provider.")
        stdout("")
        let lines = providers.map { "\($0.title) (\($0.id)/\($0.model))" }
        var picked: Int?
        if let choose {
            picked = choose(Choice(options: lines, multiple: false))?.first.flatMap { providers.indices.contains($0) ? $0 : nil }
        } else {
            for (index, line) in lines.enumerated() { stdout("    \(index + 1)  \(line)") }
            stdout("")
            while picked == nil, let line = ask("  Provider [1]: ") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    picked = 0
                } else if let number = Int(text), providers.indices.contains(number - 1) {
                    picked = number - 1
                } else if let index = providers.firstIndex(where: { $0.id == text }) {
                    picked = index
                } else {
                    stdout("    Type a number from 1 to \(providers.count).")
                }
            }
        }
        guard let picked else {
            stderr("  No provider chosen, so nothing changed.")
            return nil
        }
        stdout("  " + Style.done("\(providers[picked].title), through \(listed(providers[picked].hosts))"))
        return providers[picked]
    }

    /// A model name `--model` takes: an ASCII letter or digit, then letters, digits and
    /// `. _ - / : @ [ ]` (`anthropic/claude-haiku-5.5`, `sonnet[1m]`), up to 100 characters. It
    /// goes into the hook's `args` as one argument, and cannot start like an option.
    static func validModel(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 100,
              first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-/:@[]".unicodeScalars.contains($0))
        }
    }

    /// The agent, if any, whose hook this is: by the instructions it names, or for a hook from
    /// before those, by what its command holds.
    static func agentRunning(_ hook: Hook) -> AgentProfile? {
        if let instructions = hook.program?.instructions {
            return AgentProfile.known.first { $0.instructions == instructions }
        }
        return AgentProfile.known.first { hook.commandText.contains($0.hookMarker) }
    }

    /// A path that can go into blackice.toml: absolute, with no control character.
    static func fitsConfig(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// A TOML basic string. Callers keep control characters out (`fitsConfig`).
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The [[hook]] table for a program, as blackice.toml holds it.
    static func hookTable(_ program: HookProgram) -> [String] {
        var lines = ["[[hook]]", "on = \"connection\"", "program = " + tomlString(program.path),
                     "app = " + tomlString(program.identity.signingID)]
        if let team = program.identity.teamID { lines.append("team = " + tomlString(team)) }
        if !program.arguments.isEmpty {
            lines.append("args = [" + program.arguments.map(tomlString).joined(separator: ", ") + "]")
        }
        if !program.environment.isEmpty {
            lines.append("env = [" + program.environment.sorted { $0.key < $1.key }
                .map { tomlString($0.key + "=" + $0.value) }.joined(separator: ", ") + "]")
        }
        if !program.eventOnStdin { lines.append("stdin = \"none\"") }
        if let instructions = program.instructions { lines.append("instructions = " + tomlString(instructions.rawValue)) }
        return lines
    }

    /// The text with the table whose header is on `line` (1-based) replaced: its header and keys,
    /// up to the next table. Comments and blank lines after its last key stay.
    static func replacingTable(at line: Int, in text: String, with replacement: [String]) -> String {
        var lines = text.components(separatedBy: "\n")
        let start = line - 1
        guard lines.indices.contains(start) else { return text }
        var end = start
        for index in lines.indices.dropFirst(start + 1) {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") { end = index }
        }
        lines.replaceSubrange(start...end, with: replacement)
        return lines.joined(separator: "\n")
    }

    /// fx's settings in the agent home, with the rules of integrations/fx/README.md: ask mode, no
    /// shell at all, no edits and no web. Other keys are kept.
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
            "bash": ["*": "deny"],
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

    // MARK: - Claude Code

    /// What Claude Code's hook asks it. Its hook's `args` hold it, and nothing else does.
    static let claudeCodePrompt = "Decide the pending blackice connection in event.json."

    /// Claude Code's configuration directory in the agent home (CLAUDE_CONFIG_DIR).
    static func claudeCodeConfigDirectory(agentHome: String) -> String { agentHome + "/.claude" }

    /// Claude Code's `args`: print mode with Read as its only tool, confined to the event's
    /// directory (--restricted, which also ignores the settings files); no CLAUDE.md, hooks,
    /// plugins or MCP servers (--safe-mode, --strict-mcp-config); nothing saved; the instructions
    /// the daemon writes into the event's directory as its whole system prompt; plain text, whose
    /// last line is the answer. Checked against Claude Code 2.1.317.
    /// integrations/eval/agents/claude-code.sh runs the same (a test checks).
    static func claudeCodeArguments(model: String) -> [String] {
        ["-p", "--restricted", "--safe-mode", "--tools", "Read", "--strict-mcp-config", "--no-session-persistence",
         "--permission-prompts", "none", "--model", model, "--max-turns", "3", "--output-format", "text",
         "--system-prompt-file", "instructions.md", claudeCodePrompt]
    }

    /// What the hook asks Codex.
    static let codexPrompt = "Decide the pending blackice connection described in event.json."

    /// Codex's own home, CODEX_HOME, inside the agent home.
    static func codexHome(agentHome: String) -> String { agentHome + "/.codex" }

    /// Codex's `args`: one `codex exec` request, checked against Codex 0.166.0.
    /// - Nothing of yours: no config.toml (--ignore-user-config), no exec-policy rules
    ///   (--ignore-rules), no AGENTS.md from the working directory (project_doc_max_bytes=0), no
    ///   hooks, plugins, apps, subagents, image generation, browser or computer use, no web search,
    ///   no session saved (--ephemeral) and no history. --strict-config refuses a key it does not know.
    /// - The instructions the daemon writes into the event's directory replace Codex's own
    ///   (model_instructions_file, relative to the working directory).
    /// - Its commands run in a sandbox that reads only the event's directory and the system's own
    ///   files (`:minimal`), writes nothing and has no network. Not `--sandbox read-only`: that
    ///   reads the whole disk, your home included, and takes the place of the profile when both are given.
    ///   Nothing asks for approval (approval_policy never), and the shell is not a login shell.
    /// integrations/eval/agents/codex.sh runs the same (a test checks).
    static func codexArguments(model: String) -> [String] {
        ["exec", "--strict-config", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
         "--color", "never", "-m", model,
         "-c", "model_reasoning_effort=\"low\"",
         "-c", "model_instructions_file=\"instructions.md\"",
         "-c", "project_doc_max_bytes=0",
         "-c", "default_permissions=\"blackice\"",
         "-c", "permissions.blackice.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\"}",
         "-c", "approval_policy=\"never\"",
         "-c", "allow_login_shell=false",
         "-c", "web_search=\"disabled\"",
         "-c", "analytics.enabled=false",
         "-c", "feedback.enabled=false",
         "-c", "history.persistence=\"none\"",
         "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "multi_agent",
         "--disable", "image_generation", "--disable", "browser_use", "--disable", "computer_use",
         codexPrompt]
    }

    /// `codex login status` says "Logged in using ChatGPT" (or an API key) once it is signed in,
    /// and "Not logged in" before.
    static func codexSignedIn(_ status: String) -> Bool {
        status.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("Logged in") }
    }

    // MARK: - opencode

    /// What the hook asks opencode.
    static let openCodePrompt = "Decide whether to approve the pending blackice connection in event.json."

    /// opencode's `args`: one `opencode run` with a server of its own (--standalone: the shared
    /// background service runs with your HOME), as the blackice agent that the configuration in its
    /// environment defines. Checked against opencode 2.2.5.
    /// integrations/eval/agents/opencode.sh runs the same (a test checks).
    static func openCodeArguments(model: String) -> [String] {
        ["run", "--standalone", "--agent", "blackice", "--model", model, openCodePrompt]
    }

    /// The configuration opencode gets in OPENCODE_CONFIG_CONTENT, which comes after its global and
    /// project files and so wins over them: an agent whose whole system prompt is the instructions
    /// the daemon writes into the event's directory, its working directory, with a few steps; the
    /// read tool and no other, inside that directory (external_directory), for every agent and for
    /// this one, each tool named, since a file's rule for one would otherwise stay; no update check
    /// and no sharing.
    static let openCodeConfiguration: String = {
        let rules = ["*", "read", "bash", "edit", "glob", "grep", "task", "todowrite", "skill", "lsp", "question",
                     "webfetch", "websearch", "external_directory", "doom_loop"]
            .map { "\"\($0)\":\"\($0 == "read" ? "allow" : "deny")\"" }.joined(separator: ",")
        return "{\"agent\":{\"blackice\":{\"mode\":\"primary\",\"prompt\":\"{file:./instructions.md}\",\"steps\":4,"
            + "\"permission\":{\(rules)}}},\"autoupdate\":false,\"permission\":{\(rules)},\"share\":\"disabled\"}"
    }()

    /// opencode's environment, for its sign-in, its status and the hook:
    /// - HOME is its own folder in the agent home, where it keeps its sign-in and its sessions.
    /// - XDG_CONFIG_HOME is `.`: its global configuration folder is `opencode/` in its working
    ///   directory, which it creates empty. For the hook that is the event's new private
    ///   directory, so no opencode.json, AGENTS.md, plugin or skill that a program wrote into a
    ///   folder of yours is loaded.
    /// - No project files either (OPENCODE_DISABLE_PROJECT_CONFIG: no opencode.json or AGENTS.md
    ///   from the folders above the event's), nothing of ~/.claude, no update check and no model
    ///   list from the network: it knows the models of a provider it is signed in to.
    static func openCodeEnvironment(agentHome: String) -> [String: String] {
        ["HOME": openCodeHome(agentHome: agentHome), "XDG_CONFIG_HOME": ".",
         "OPENCODE_CONFIG_CONTENT": openCodeConfiguration,
         "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1",
         "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1"]
    }

    /// opencode's HOME inside the agent home.
    static func openCodeHome(agentHome: String) -> String { agentHome + "/.opencode" }

    /// `opencode auth list --format json` lists the integrations it can use, each with how it
    /// connects. Signed in means a sign-in stored for this provider: one through a variable of
    /// your shell (`"type": "env"`) does not reach the hook, which gets none of them.
    static func openCodeSignedIn(_ status: String, provider: String) -> Bool {
        guard let start = status.firstIndex(of: "["), let end = status.lastIndex(of: "]"), start < end,
              let list = try? JSONSerialization.jsonObject(with: Data(status[start...end].utf8)) as? [[String: Any]] else {
            return false
        }
        return list.contains { item in
            let connections = item["connections"] as? [[String: Any]] ?? []
            return item["id"] as? String == provider && connections.contains { ($0["type"] as? String).map { $0 != "env" } ?? false }
        }
    }

    /// What replaces fx's built-in system prompt in the hook (`fx ask --system`). fx still adds its
    /// tools and the blackice skill, which says how to decide.
    static let fxSystemPrompt = "You answer for blackice, a network filter on a Mac: one app wants to reach one host, and you decide whether to approve it. The blackice skill in this workspace says how to read the event and how to answer. Follow it exactly and answer in its format."

    /// `claude auth status --json` prints an object whose `loggedIn` is true once it is signed in.
    static func claudeCodeSignedIn(_ status: String) -> Bool {
        guard let start = status.firstIndex(of: "{"), let end = status.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(status[start...end].utf8)) as? [String: Any] else {
            return false
        }
        return object["loggedIn"] as? Bool == true
    }

    /// The test's run read the way the daemon reads a hook: an answer only from a run that exited
    /// with status 0 in time, and only as its last line of output.
    static func testAnswer(_ result: HookResult, seconds: Int) -> TestAnswer {
        switch result.answer {
        case .success(let answer)?: return .answered(answer)
        case .failure(.output(.noLine))?: return .none("exited with status 0 and gave no answer")
        case .failure(.output(.unrecognized(let prefix)))?:
            return .none("ended with a line that is not an answer (\"\(prefix)\")")
        case .failure(.output(.outputTooLong))?:
            return .none("printed more than \(HookAnswer.maximumOutputBytes / 1024) KiB, so its last line is not known")
        case .failure(.exitStatus(let status))?: return .none("exited with status \(status) and gave no answer")
        case .failure(.signaled(let signal))?: return .none("died from signal \(signal)")
        case .failure(.deadline)?: return .none("gave no answer in \(seconds) s")
        case nil:
            switch result.outcome {
            case .refused(let found): return .none("is signed as \(found) and the hook would not start it")
            case .failedToStart(let reason): return .none("did not start: \(reason)")
            case .dropped(let reason): return .none("did not run (\(reason.rawValue))")
            case .exited, .signaled, .timedOut: return .none("gave no answer")
            }
        }
    }

    /// The rule and hook to add to blackice.toml; empty when both are there already.
    static func agentAddition(_ name: String, identity: SigningIdentity, hosts: [String], hook: HookProgram?) -> String {
        guard !hosts.isEmpty || hook != nil else { return "" }
        var lines = ["", "# \(name) answers the connections that wait in ask mode (added by blackice agent connect \(name))."]
        if !hosts.isEmpty {
            lines += ["[[allow]]", "app = \"\(identity.signingID)\""]
            if let team = identity.teamID { lines.append("team = \"\(team)\"") }
            lines.append("hosts = [" + hosts.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        }
        if let hook {
            if !hosts.isEmpty { lines.append("") }
            lines += hookTable(hook)
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

    /// The sample event fx decides in the test: an app it should approve. The token (which fx never
    /// sees) and the deadline are fresh.
    static func sampleAgentEvent(now: Date = Date()) throws -> HookEvent {
        try HookEvent.connection(
            app: HookEvent.App(signingID: "com.microsoft.VSCode", teamID: "UBF8T346G9",
                               path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            host: "update.code.visualstudio.com", ip: "13.107.246.40", port: 443,
            deadline: now.addingTimeInterval(TimeInterval(agentTestSeconds)))
    }

    static let agentTestSeconds = 120

    // MARK: - The command

    /// `firstStep` numbers the steps on from where `blackice start` left off when it runs this
    /// right after the first start (`fromFirstStart`), which loaded the file in accept-all.
    static func connectAgent(_ name: String, configPath: String?, model chosenModel: String? = nil, readFile: (String) throws -> Data,
                             system: SystemControlling, interaction: Interaction, machine: AgentMachine,
                             stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void,
                             firstStep: Int = 1, fromFirstStart: Bool = false) -> Int32 {
        // Control-C and the other stop signals end the setup at its next check instead of ending
        // blackice, so that what follows can put things back. Released last: defers run last first.
        let releaseInterrupts = machine.catchInterrupts()
        defer { releaseInterrupts() }
        // Accept-all lets everything through, so a setup that switched to it and then stops before
        // the last step loads the file, whatever the reason, switches back to the mode it put off.
        // Before the first start nothing was filtered: after it, the setup stays in accept-all and
        // says so.
        var putOff: Mode?
        var loadedFile = false
        var reached: String?
        defer {
            if !loadedFile, let putOff {
                leaveAcceptAll(for: putOff, system: system, stdout: stdout, stderr: stderr)
            } else if !loadedFile, fromFirstStart {
                let retry = "blackice agent connect \(name)" + (configPath.map { " --config \(Describe.path($0, home: interaction.home))" } ?? "")
                reportAcceptAll(name, reached: reached, interrupted: machine.interrupted(), retry: retry,
                                system: system, stderr: stderr)
            }
        }
        guard var profile = AgentProfile.known.first(where: { $0.name == name }) else {
            stderr("blackice agent connect knows \(listed(AgentProfile.known.map(\.name))): " +
                   "blackice agent connect fx")
            return ExitCode.usage
        }
        let name = profile.name
        guard chosenModel.map(validModel) ?? true else {
            stderr("agent connect: --model takes a model name such as \(profile.defaultModel)")
            return ExitCode.usage
        }
        guard let ask = interaction.ask else {
            stderr("blackice agent connect asks questions and signs \(profile.name) in, so it needs a terminal.")
            return ExitCode.usage
        }
        let path = configPath ?? defaultConfigPath
        let shown = Describe.path(path, home: interaction.home)
        var text: String
        var config: BlackiceConfig
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
        var number = firstStep
        func step(_ title: String) {
            stdout(""); stdout(Style.heading("\(number) · \(title)")); stdout("")
            reached = "step \(number) (\(title))"
            number += 1
        }
        func fail(_ status: Int32, _ lines: String...) -> Int32 { lines.forEach { stderr("  " + $0) }; return status }
        // Checked after each wait: a prompt, a program, Touch ID.
        func interruption() -> Int32? {
            guard machine.interrupted() else { return nil }
            stderr("  Interrupted, so the setup stops here.")
            return ExitCode.interrupted
        }

        if firstStep == 1 {
            stdout("Connecting \(name) to blackice: it will answer the connections that wait in")
            stdout("ask mode, with nobody at the keyboard.")
        }
        // An agent that decides with a provider of your choice: `--model PROVIDER/MODEL` names it,
        // or a list asks. Its rule names that provider's hosts.
        if let forProvider = profile.forProvider {
            guard let provider = chooseProvider(profile, model: chosenModel, choose: interaction.choose, ask: ask,
                                                stdout: stdout, stderr: stderr) else {
                if machine.interrupted() {
                    stderr("  Interrupted, so the setup stops here.")
                    return ExitCode.interrupted
                }
                return ExitCode.usage
            }
            profile = forProvider(provider)
        }
        let model = chosenModel ?? profile.defaultModel
        // What to run to try again: from blackice start, the file is written and start would
        // only load it, so the retry is agent connect itself. With the provider chosen in a list,
        // its model too, so that the list is not asked again.
        let retryModel = chosenModel ?? (profile.provider == nil ? nil : model)
        let retry = "blackice agent connect \(name)" + (configPath.map { " --config \(Describe.path($0, home: interaction.home))" } ?? "")
            + (retryModel.map { $0.contains("[") ? " --model '\($0)'" : " --model \($0)" } ?? "")
        // Filtering in ask or block-all, the agent's installer, sign-in and test would wait for an
        // answer nobody gives yet: accept-all until the last step loads the file again.
        if let running = system.runningMode(), running != .acceptAll {
            stdout("")
            stdout("blackice is in \(running.rawValue) mode, so \(name)'s installer, its sign-in and the test")
            stdout("would wait for an answer nobody gives yet. It switches to accept-all while")
            stdout("\(name) is set up; the last step loads \(shown) again. If the setup stops")
            stdout("before that, it switches back to \(running.rawValue) mode.")
            putOff = running
            let switched = system.setMode(.acceptAll, output: SystemOutput(stdout: stdout, stderr: stderr))
            guard switched == ExitCode.success else { return switched }
            if let stop = interruption() { return stop }
        }

        // 1. Find it and read its signature. A development build first on PATH may be unsigned or
        // ad hoc signed, which no rule can name: the first signed copy is the one used, and
        // blackice can install one for itself where the agent's installer allows it.
        step("Find \(name)")
        let paths = AgentPaths(userHome: interaction.home, profile: profile)
        let binShown = Describe.path(paths.bin, home: interaction.home)
        let alsoIn = [paths.bin] + profile.installFolders.map { interaction.home + "/" + $0 }
        func lookUp() -> [String] { machine.findExecutables(profile.executable, alsoIn) }
        func firstSigned(_ candidates: [String]) -> (path: String, identity: SigningIdentity)? {
            for path in candidates {
                if let identity = interaction.identify((path as NSString).resolvingSymlinksInPath) { return (path, identity) }
            }
            return nil
        }
        var found = lookUp()
        if found.isEmpty, let installer = profile.installer {
            stdout("  \(name) is not installed. Its installer, from \(profile.installHint):")
            stdout("    " + Style.command(installer))
            while found.isEmpty {
                guard let line = ask("  Install \(name) now? [Y/n]: ") else { break }
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                if ["n", "no"].contains(answer) { break }
                guard ["", "y", "yes"].contains(answer) else { stdout("    Type y or n."); continue }
                stdout("")
                // pipefail: in `curl … | bash` a failed download is curl's status, not bash's 0.
                let status = machine.runAttached("/bin/bash", ["-o", "pipefail", "-c", installer], [:])
                stdout("")
                if let stop = interruption() { return stop }
                found = lookUp()
                if found.isEmpty {
                    return fail(ExitCode.unavailable, "\(name)'s installer exited with status \(status), and \(name) is still not",
                                "on PATH or in ~/\(profile.installFolders.first ?? ".local/bin"). Install it (\(profile.installHint)), then: \(retry)")
                }
            }
        }
        if let stop = interruption() { return stop }
        guard let first = found.first else {
            return fail(ExitCode.unavailable, "\(name) is not installed. Install it (\(profile.installHint)),",
                        "then: \(retry)")
        }
        let shownFirst = Describe.terminalSafe(Describe.path(first, home: interaction.home))
        var signed = firstSigned(found)
        if signed == nil, let installer = profile.installer, let privateInstall = profile.privateInstall {
            stdout("  \(shownFirst) is unsigned or ad hoc signed, as development builds are, so a rule")
            stdout("  cannot name it. blackice can install \(name)'s signed release for itself only, in")
            stdout("  \(binShown). Yours stays as it is, and so does your PATH.")
            while signed == nil {
                guard let line = ask("  Install it there? [Y/n]: ") else { break }
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                if ["n", "no"].contains(answer) { break }
                guard ["", "y", "yes"].contains(answer) else { stdout("    Type y or n."); continue }
                do {
                    let parent = (paths.home as NSString).deletingLastPathComponent
                    if !FileManager.default.fileExists(atPath: parent) {
                        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                    }
                    try privateFolder(paths.home)
                    try privateFolder(paths.bin)
                } catch {
                    return fail(ExitCode.cannotCreate, "Cannot set up \(binShown): \(describe(error))")
                }
                stdout("")
                let status = machine.runAttached("/bin/bash", ["-o", "pipefail", "-c", installer], privateInstall(paths.bin))
                stdout("")
                if let stop = interruption() { return stop }
                signed = firstSigned(lookUp())
                if signed == nil {
                    return fail(ExitCode.unavailable, "\(name)'s installer exited with status \(status), and no signed \(name) is in",
                                "\(binShown) either. Install \(name)'s release (\(profile.installHint)), then: \(retry)")
                }
            }
        }
        if let stop = interruption() { return stop }
        guard let (executable, identity) = signed else {
            return fail(ExitCode.unavailable, "\(shownFirst) is unsigned or ad hoc signed, so a rule cannot name it.")
        }
        let shownExecutable = Describe.terminalSafe(Describe.path(executable, home: interaction.home))
        guard fitsConfig(executable) else {
            return fail(ExitCode.unavailable, "\(shownExecutable) has a control character in its path, which blackice.toml cannot hold.")
        }
        if executable != first {
            stdout("  \(shownFirst) is unsigned or ad hoc signed, so blackice uses \(shownExecutable).")
        }
        stdout("  " + Style.done("\(shownExecutable) is \(ConfigWizard.describe(identity))"))

        // 2. Its own home: a sign-in, and the rules. The instructions are not there: the daemon
        // writes them, from blackice itself, into each event's directory.
        step("Give \(name) a home of its own")
        let homeShown = Describe.path(paths.home, home: interaction.home)
        guard fitsConfig(paths.home) else {
            return fail(ExitCode.unavailable, "\(homeShown) has a control character in its path, which blackice.toml cannot hold.")
        }
        let files = FileManager.default
        do {
            let parent = (paths.home as NSString).deletingLastPathComponent
            if !files.fileExists(atPath: parent) {
                try files.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for folder in paths.folders { try privateFolder(folder) }
        } catch {
            return fail(ExitCode.cannotCreate, "Cannot set up \(homeShown): \(describe(error))")
        }
        stdout("  " + Style.done("Its home is \(homeShown); its instructions come with blackice"))
        let environment = profile.environment(paths.home)
        func signedIn() -> Bool { profile.signedIn(machine.runCaptured(executable, profile.statusArguments, environment).output) }
        if signedIn() {
            stdout("  " + Style.done("\(name) is signed in there"))
        } else {
            stdout("  Sign \(name) in for blackice.")
            profile.loginHint.forEach { stdout("  " + $0) }
            // A sign-in can fail on its own (a closed page, a connection cut as the filter came up):
            // offer it again instead of making the person start over.
            var signed = false
            while !signed {
                stdout("")
                _ = machine.runAttached(executable, profile.loginArguments, environment)
                stdout("")
                if let stop = interruption() { return stop }
                signed = signedIn()
                if signed { break }
                guard let line = ask("  \(name) is not signed in yet. Try again? [Y/n]: "),
                      !["n", "no"].contains(line.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    if let stop = interruption() { return stop }
                    return fail(ExitCode.software, "\(name) is still not signed in, so nothing else changed. To retry: \(retry)")
                }
            }
            stdout("  " + Style.done("\(name) is signed in"))
        }
        if let settingsPath = paths.settings, let makeSettings = profile.settings {
            do {
                let settings = try makeSettings(files.contents(atPath: settingsPath))
                try writeAtomically(settings, to: settingsPath, mode: 0o600)
            } catch {
                return fail(ExitCode.cannotCreate, "Cannot write \(Describe.path(settingsPath, home: interaction.home)): \(describe(error))")
            }
            stdout("  " + Style.done("There, \(name) may read files and nothing else: no shell, no edits, no web"))
        } else if let limits = profile.limits {
            stdout("  " + Style.done(limits))
        }

        // 3. One sample event through the hook runner. The answer is only read, never passed on.
        step("Try it on a sample connection")
        let event: HookEvent
        do {
            if files.fileExists(atPath: paths.test) { try files.removeItem(atPath: paths.test) }
            try PrivateDirectory.ensure(URL(fileURLWithPath: paths.test))
            event = try sampleAgentEvent()
        } catch {
            return fail(ExitCode.cannotCreate, "Cannot set up the test in \(homeShown): \(describe(error))")
        }
        defer { try? files.removeItem(atPath: paths.test) }
        stdout("  It decides with \(model)" + (chosenModel != nil ? "."
            : profile.provider == nil ? "; --model NAME picks another." : "; --model PROVIDER/MODEL picks another."))
        stdout("  \(name) is deciding whether Visual Studio Code may reach")
        stdout("  update.code.visualstudio.com. Its answer is only read for this test, so")
        stdout("  nothing is let through…")
        let program = agentHook(profile, executable: executable, agentHome: paths.home, identity: identity, model: model)
        let result = machine.runHook(Hook(program: program, line: 0), event, config.agentNotes, paths.test + "/work",
                                     agentTestSeconds)
        if let stop = interruption() { return stop }
        let seconds = Int(result.duration.rounded())
        switch testAnswer(result, seconds: agentTestSeconds) {
        case .answered(.approve):
            stdout("  " + Style.done("\(name) approved it in \(seconds) s"))
        case .answered(.deny):
            stdout("  " + Style.done("\(name) answered in \(seconds) s (it denied it; any answer shows the wiring works)"))
        case .none(let why):
            stderr("  \(name) \(why), so blackice.toml was left as it was.")
            // What it wrote to stderr, then to stdout: Claude Code prints its errors ("Not logged
            // in") on stdout.
            let output = [result.stderr, String(decoding: result.stdout, as: UTF8.self)].filter { !$0.isEmpty }
                .joined(separator: "\n")
            let tail = output.split(whereSeparator: \.isNewline).suffix(8)
            if !tail.isEmpty {
                stderr("  \(name)'s last lines:")
                tail.forEach { stderr("    " + Describe.terminalSafe(String($0.prefix(200)))) }
            }
            let advice = profile.advice(output)
            if advice.isEmpty {
                stderr("  If blackice is in ask or block-all mode, \(name)'s own connections wait too: switch to")
                stderr("  accept-all (blackice mode accept-all), then: \(retry)")
            } else {
                advice.forEach { stderr("  " + $0) }
                stderr("  To retry: \(retry)")
            }
            return ExitCode.software
        }

        // 4. The rule for its model, the hook, and time enough to answer. The file is read again:
        // edits made during the sign-in and the test are kept, and the additions go on top of them.
        step("Add \(name) to \(shown)")
        switch loadConfig(path, readFile: readFile, stderr: stderr, shown: shown, hint: true) {
        case .failure(let status):
            return status.code
        case .success(let current):
            if current.text != text { stdout("  \(shown) changed while \(name) was set up; the additions go on top of that.") }
            text = current.text
            config = current.config
        }
        let missing = profile.hosts.filter { config.allowRule(for: identity, host: $0) == nil }
        // Each agent keeps a hook of its own, and `answers` in [agent] says which one answers, so
        // `blackice mode ask --agent NAME` and the menu switch between them. This agent's first
        // hook becomes its new one, or stays as it is when it is that already. A hook that runs an
        // agent without naming its instructions (a `run` line from before 0.4.0, which no signature
        // check covers, or a program from 0.4.0) would run whatever `answers` says: the first one
        // becomes this agent's when it has none, and the others go, the last first, so the lines
        // before them stay where they are. Other agents' hooks with instructions stay.
        let agentHooks = config.hooks.filter { agentRunning($0) != nil }
        let unnamed = agentHooks.filter { $0.program?.instructions == nil }
        let own = agentHooks.filter { agentRunning($0)?.name == name && $0.program?.instructions == profile.instructions }
        let existingHook = own.first ?? unnamed.first { agentRunning($0)?.name == name } ?? unnamed.first
        let goners = agentHooks.filter { hook in
            hook.line != existingHook?.line && (hook.program?.instructions == nil || own.contains { $0.line == hook.line })
        }
        let staying = agentHooks.filter { hook in hook.line != existingHook?.line && !goners.contains { $0.line == hook.line } }
        let keptHook = existingHook.map { $0.program == program && $0.on == "connection" } ?? false
        var updated = text
        for extra in goners.reversed() where extra.line > (existingHook?.line ?? 0) {
            updated = replacingTable(at: extra.line, in: updated, with: [])
        }
        if let existingHook, !keptHook {
            updated = replacingTable(at: existingHook.line, in: updated, with: hookTable(program))
        }
        for extra in goners.reversed() where extra.line < (existingHook?.line ?? 0) {
            updated = replacingTable(at: extra.line, in: updated, with: [])
        }
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += agentAddition(name, identity: identity, hosts: missing, hook: existingHook == nil ? program : nil)
        // With another agent's hook there too, or `answers` set already, `answers` names this one.
        let answerer = Answerer.agent(profile.instructions)
        let answersSet = !staying.isEmpty || config.answers != nil
        if answersSet {
            do {
                updated = try BlackiceConfig.settingAnswers(answerer, in: updated)
            } catch {
                return fail(ExitCode.software, "Cannot set answers in \(shown): \(error)")
            }
        }
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
        if let existingHook, keptHook {
            stdout("  A hook already starts \(name) (line \(existingHook.line)); it stays as it is.")
        } else if let existingHook, let other = agentRunning(existingHook), other.name != name {
            stdout("  " + Style.done("The hook on line \(existingHook.line) ran \(other.name) without naming its instructions;"))
            stdout("    it now starts \(name) instead, once its signature checks out")
        } else if let existingHook, existingHook.program?.instructions == profile.instructions {
            stdout("  " + Style.done("The hook on line \(existingHook.line) now starts \(name) with \(model)"))
        } else if let existingHook {
            stdout("  " + Style.done("The hook on line \(existingHook.line) now starts \(name) itself, once its signature checks out"))
        } else {
            stdout("  " + Style.done("A hook starts \(name) for each connection that waits, once its signature checks out"))
        }
        for extra in goners {
            stdout("  " + Style.done("The hook on line \(extra.line), which ran \(agentRunning(extra)?.name ?? "an agent"), is gone"))
        }
        if answersSet {
            let others = staying.compactMap { agentRunning($0)?.name }
            stdout("  " + Style.done("\(name) answers ([agent] answers = \"\(name)\")") +
                   (others.isEmpty ? "" : "; \(listed(others))'s hook stays,"))
            if let first = others.first {
                stdout("    for: blackice mode ask --agent \(first), or the menu's Mode")
            }
        }
        if raisedTimeout {
            stdout("  " + Style.done("timeout_seconds is now \(min(neededSeconds, BlackiceConfig.timeoutRange.upperBound)), " +
                                     "so \(name) has time to answer"))
        }
        let saved = save(updated, over: text, at: path, shown: shown, stdout: stdout, stderr: stderr)
        guard var loaded = saved.text else { return saved.status }

        // 5. Load it, in ask mode if the person wants, and make sure the daemon runs.
        step("Turn it on")
        var mode = config.mode
        if mode != .ask {
            stdout("  In ask mode, a connection no rule covers waits until \(name) answers (\(seconds) s on")
            stdout("  the test); with no answer in time it is denied.")
            while true {
                guard let line = ask("  Switch to ask mode now? [y/N]: ") else {
                    if let stop = interruption() { return stop }
                    break // The end of input: no, the default.
                }
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                if ["y", "yes"].contains(answer) {
                    let switched = save(settingRootKey(loaded, "mode", to: "\"ask\""), over: loaded, at: path,
                                        shown: shown, stdout: stdout, stderr: stderr)
                    guard let written = switched.text else { return switched.status }
                    loaded = written
                    mode = .ask
                    break
                }
                if ["", "n", "no"].contains(answer) { break }
                stdout("    Type y or n.")
            }
        }
        stdout("")
        if let stop = interruption() { return stop }
        let started = system.start(configText: loaded, output: SystemOutput(stdout: stdout, stderr: stderr))
        guard started == ExitCode.success else { return started }
        loadedFile = true
        // The hook loaded now names its instructions, so the copies made up to 0.4.0 are read by
        // nothing, and only invite a change that no hook would see. Gone only now: until this
        // load, the configuration in force could still be a hook that reads them.
        let removed = paths.oldCopies.filter { files.fileExists(atPath: $0) && (try? files.removeItem(atPath: $0)) != nil }
        if !removed.isEmpty {
            stdout("  " + Style.done("Removed the copies of the instructions earlier versions put in \(homeShown)"))
        }
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

    /// After a setup that switched to accept-all and did not load the file: switches back to `mode`,
    /// the one in force before. Only when the saved mode is still accept-all, so a switch that never
    /// happened is not undone. It takes Touch ID once more, as the last step would have; without
    /// it, says how to leave accept-all by hand.
    static func leaveAcceptAll(for mode: Mode, system: SystemControlling, stdout: @escaping (String) -> Void,
                               stderr: @escaping (String) -> Void) {
        guard mode != .acceptAll, system.runningMode() == .acceptAll else { return }
        stdout("")
        stdout("The setup did not finish, so blackice leaves accept-all for \(mode.rawValue) mode.")
        guard system.setMode(mode, output: SystemOutput(stdout: stdout, stderr: stderr)) != ExitCode.success else { return }
        stderr("blackice is still in accept-all mode: every connection goes through. To leave it: blackice mode \(mode.rawValue)")
    }

    /// After a first start whose agent setup did not load the file. That start left blackice on in
    /// accept-all, and nothing was filtered before it, so it stays that way rather than hold each
    /// connection no rule covers until someone answers by hand. Says so plainly, and how to go on.
    static func reportAcceptAll(_ name: String, reached: String?, interrupted: Bool, retry: String,
                                system: SystemControlling, stderr: (String) -> Void) {
        guard system.runningMode() == .acceptAll else { return }
        let at = reached.map { " at \($0)" } ?? ""
        stderr("")
        stderr("blackice is on in accept-all mode and filters nothing: every connection goes through.")
        stderr(interrupted ? "The \(name) setup was interrupted\(at)." : "The \(name) setup failed\(at), for the reason above.")
        stderr("To finish it: \(retry)")
        stderr("To filter without an agent: blackice mode ask, or blackice mode block-all")
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

    /// Writes the new text if it parses and the file still holds `previous`, keeping the file's
    /// mode. The text written (or `previous`, when there is nothing to change), or nil and the exit
    /// status. Whatever else wrote the file meanwhile, an editor or another agent connect, stays.
    private static func save(_ text: String, over previous: String, at path: String, shown: String,
                             stdout: (String) -> Void, stderr: (String) -> Void) -> (text: String?, status: Int32) {
        func changed() -> (text: String?, status: Int32) {
            stderr("  Something else changed \(shown) meanwhile, so blackice agent connect left it as it is. Run it again.")
            return (nil, ExitCode.tempFail)
        }
        guard text != previous else {
            return FileManager.default.contents(atPath: path) == Data(previous.utf8) ? (text, ExitCode.success) : changed()
        }
        do {
            _ = try BlackiceConfig(data: Data(text.utf8))
        } catch {
            stderr("  blackice agent connect: the file it would write does not parse (\(error)); nothing was written")
            return (nil, ExitCode.cannotCreate)
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        do {
            try writeAtomically(Data(text.utf8), to: path, mode: mode_t(mode), replacing: Data(previous.utf8))
        } catch is ChangedMeanwhile {
            return changed()
        } catch {
            stderr("  Cannot write \(shown): \(error.localizedDescription)")
            return (nil, ExitCode.cannotCreate)
        }
        stdout("    Saved \(shown)")
        return (text, ExitCode.success)
    }

    /// The file did not hold what `writeAtomically` was told to replace.
    struct ChangedMeanwhile: Error {}

    /// Replaces a file through a temporary file in the same folder. With `expected`, only while the
    /// file holds exactly that, checked just before the rename.
    static func writeAtomically(_ data: Data, to path: String, mode: mode_t, replacing expected: Data? = nil) throws {
        let temporary = temporaryPath(for: path)
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard fchmodat(AT_FDCWD, temporary, mode, 0) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
            if let expected, FileManager.default.contents(atPath: path) != expected { throw ChangedMeanwhile() }
            guard rename(temporary, path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// The temporary file beside `path`: in its folder, or in the current one for a bare file
    /// name such as `--config blackice.toml`, which has no folder to put in front.
    static func temporaryPath(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = ".\((path as NSString).lastPathComponent).\(getpid()).tmp"
        return folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)
    }
}
