import NetshieldCore

/// Where a system command writes its lines.
public struct SystemOutput {
    public let stdout: (String) -> Void
    public let stderr: (String) -> Void

    public init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The commands that talk to macOS: activating the extension and saving the filter preference.
/// The real implementation is NetshieldSystem.NESystemControl; tests and unsigned builds use
/// `UnsignedSystem`. Each method returns the exit status.
public protocol SystemControlling {
    func start(configText: String, output: SystemOutput) -> Int32
    func stop(output: SystemOutput) -> Int32
    func status(output: SystemOutput) -> Int32
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32
}

/// What every build says that is not Netshield.app signed with the Developer ID.
public struct UnsignedSystem: SystemControlling {
    public init() {}

    public static func refusal(_ command: String) -> String {
        "netshield \(command): needs Netshield.app signed with the Developer ID; this build is not, " +
            "so macOS will not load its network extension (see docs/phase-0.md)"
    }

    public func start(configText: String, output: SystemOutput) -> Int32 { refuse("start", output) }
    public func stop(output: SystemOutput) -> Int32 { refuse("stop", output) }
    public func status(output: SystemOutput) -> Int32 { refuse("status", output) }
    public func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { refuse("mode", output) }

    private func refuse(_ command: String, _ output: SystemOutput) -> Int32 {
        output.stderr(Self.refusal(command))
        return ExitCode.unavailable
    }
}
