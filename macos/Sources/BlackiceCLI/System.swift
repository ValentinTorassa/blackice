import BlackiceCore

/// Where a system command writes its lines.
public struct SystemOutput {
    public let stdout: (String) -> Void
    public let stderr: (String) -> Void
    /// The first start, right after the questions (step 1): start numbers Touch ID step 2 and
    /// allowing the extension step 3.
    public let setup: Bool
    /// Whether the first start ends with the "Next" commands; not when more setup follows.
    public let next: Bool

    public init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void, setup: Bool = false,
                next: Bool = true) {
        self.stdout = stdout
        self.stderr = stderr
        self.setup = setup
        self.next = next
    }
}

/// The commands that talk to macOS: activating the extension, saving the filter preference,
/// reaching the extension over XPC, and loading the daemon's LaunchAgent. The real implementation
/// is BlackiceSystem.NESystemControl; tests and unsigned builds use `UnsignedSystem`. Each method
/// returns the exit status.
public protocol SystemControlling {
    func start(configText: String, output: SystemOutput) -> Int32
    func stop(output: SystemOutput) -> Int32
    func status(output: SystemOutput) -> Int32
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32
    /// `blackice pending`: the paused connections and the approvals.
    func pending(output: SystemOutput) -> Int32
    /// `blackice approve` and `deny`. Confirms a person with Touch ID first.
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32
    /// `blackice daemon`: registers with the extension, takes the configuration it holds, and runs
    /// that configuration's hooks for each event until the connection ends.
    func runDaemon(output: SystemOutput) -> Int32
    /// `blackice agent install`: writes the daemon's LaunchAgent and loads it. No Touch ID.
    func installAgent(output: SystemOutput) -> Int32
    /// `blackice agent uninstall`: unloads the LaunchAgent and removes it. No Touch ID.
    func uninstallAgent(output: SystemOutput) -> Int32
    /// The mode blackice filters in now; nil when it is not filtering (or that cannot be read).
    func runningMode() -> Mode?
}

extension SystemControlling {
    public func runningMode() -> Mode? { nil }
}

/// What every build says that is not Blackice.app signed with the Developer ID.
public struct UnsignedSystem: SystemControlling {
    public init() {}

    /// Also what a person sees who runs the command through a symbolic link, since then the
    /// process is not the signed app.
    public static func refusal(_ command: String) -> String {
        "blackice \(command) works only from Blackice.app in /Applications, signed with its Developer ID. " +
            "Run /Applications/Blackice.app/Contents/MacOS/blackice, or the blackice command the installer added; " +
            "a symbolic link to it does not work."
    }

    public func start(configText: String, output: SystemOutput) -> Int32 { refuse("start", output) }
    public func stop(output: SystemOutput) -> Int32 { refuse("stop", output) }
    public func status(output: SystemOutput) -> Int32 { refuse("status", output) }
    public func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { refuse("mode", output) }
    public func pending(output: SystemOutput) -> Int32 { refuse("pending", output) }
    public func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { refuse(request.kind.rawValue, output) }
    public func runDaemon(output: SystemOutput) -> Int32 { refuse("daemon", output) }
    public func installAgent(output: SystemOutput) -> Int32 { refuse("agent", output) }
    public func uninstallAgent(output: SystemOutput) -> Int32 { refuse("agent", output) }

    private func refuse(_ command: String, _ output: SystemOutput) -> Int32 {
        output.stderr(Self.refusal(command))
        return ExitCode.unavailable
    }
}

/// `blackice agent install` and `uninstall` as NESystemControl runs them. They need neither Touch
/// ID nor the Developer ID signature; install only refuses a binary outside Blackice.app, before
/// it touches anything. The parts come in as functions so tests can use a temporary home and a
/// fake launchctl.
public struct AgentCommands {
    public let account: () throws -> UserAccount
    /// The running binary's path, symlinks resolved.
    public let binary: () -> String?
    public let launchctl: ([String]) -> LaunchctlResult

    public init(account: @escaping () throws -> UserAccount, binary: @escaping () -> String?,
                launchctl: @escaping ([String]) -> LaunchctlResult) {
        self.account = account
        self.binary = binary
        self.launchctl = launchctl
    }

    /// The real user, the running binary and /bin/launchctl.
    public static var live: AgentCommands {
        AgentCommands(account: UserAccount.current, binary: LaunchAgent.runningBinary, launchctl: LaunchAgent.run)
    }

    public func install(output: SystemOutput) -> Int32 {
        let path: String
        do {
            path = try LaunchAgent.checkBundledBinary(binary() ?? "an unknown path")
        } catch {
            output.stderr("blackice agent install: \(error)")
            return ExitCode.unavailable
        }
        do {
            try LaunchAgentInstaller(account: try account(), launchctl: launchctl).install(binary: path, say: output.stdout)
            return ExitCode.success
        } catch {
            output.stderr("blackice agent install: \(error)")
            return ExitCode.software
        }
    }

    public func uninstall(output: SystemOutput) -> Int32 {
        do {
            try LaunchAgentInstaller(account: try account(), launchctl: launchctl).uninstall(say: output.stdout)
            return ExitCode.success
        } catch {
            output.stderr("blackice agent uninstall: \(error)")
            return ExitCode.software
        }
    }
}
