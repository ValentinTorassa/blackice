import BlackiceCore

/// Where a system command writes its lines.
public struct SystemOutput {
    public let stdout: (String) -> Void
    public let stderr: (String) -> Void

    public init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The commands that talk to macOS: activating the extension, saving the filter preference, and
/// reaching the extension over XPC. The real implementation is BlackiceSystem.NESystemControl;
/// tests and unsigned builds use `UnsignedSystem`. Each method returns the exit status.
public protocol SystemControlling {
    func start(configText: String, output: SystemOutput) -> Int32
    func stop(output: SystemOutput) -> Int32
    func status(output: SystemOutput) -> Int32
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32
    /// `blackice pending`: the paused connections and the approvals.
    func pending(output: SystemOutput) -> Int32
    /// `blackice approve` and `deny`. Without a token, confirms a person with Touch ID first.
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32
    /// `blackice daemon`: receives events from the extension and runs the hooks until the
    /// connection ends.
    func runDaemon(config: BlackiceConfig, output: SystemOutput) -> Int32
}

/// What every build says that is not Blackice.app signed with the Developer ID.
public struct UnsignedSystem: SystemControlling {
    public init() {}

    public static func refusal(_ command: String) -> String {
        "blackice \(command): needs Blackice.app signed with the Developer ID; this build is not, " +
            "so macOS will not load its network extension (see docs/phase-0.md)"
    }

    public func start(configText: String, output: SystemOutput) -> Int32 { refuse("start", output) }
    public func stop(output: SystemOutput) -> Int32 { refuse("stop", output) }
    public func status(output: SystemOutput) -> Int32 { refuse("status", output) }
    public func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { refuse("mode", output) }
    public func pending(output: SystemOutput) -> Int32 { refuse("pending", output) }
    public func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { refuse(request.kind.rawValue, output) }
    public func runDaemon(config: BlackiceConfig, output: SystemOutput) -> Int32 { refuse("daemon", output) }

    private func refuse(_ command: String, _ output: SystemOutput) -> Int32 {
        output.stderr(Self.refusal(command))
        return ExitCode.unavailable
    }
}
