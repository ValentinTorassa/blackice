import Foundation

/// Where the daemon's events come from: connections the extension paused in ask mode.
///
/// Phase 2 implements this over XPC from the extension. Until then only tests provide events.
/// Do not back it with a socket, a file or anything else another local process could write to:
/// a forged event would make the daemon run hooks with data the attacker chose.
public protocol EventIntake: Sendable {
    func events() -> AsyncStream<HookEvent>
}

/// The user-level side of netshield: takes paused connections from the intake, runs the hooks
/// for each one and records everything in the event log. It does not decide anything itself;
/// the answers go from the hooks to the extension through `netshield approve` and `deny`.
public final class Daemon: Sendable {
    public let config: NetshieldConfig
    public let log: EventLog
    public let runner: HookRunner
    private let reportLogFailure: @Sendable (Error) -> Void

    /// `reportLogFailure` is called for every record the log could not take. The default prints
    /// to stderr, which the LaunchAgent sends to its own file.
    public init(config: NetshieldConfig, log: EventLog, runner: HookRunner,
                reportLogFailure: @escaping @Sendable (Error) -> Void = Daemon.printLogFailure) {
        self.config = config
        self.log = log
        self.runner = runner
        self.reportLogFailure = reportLogFailure
    }

    /// Handles events until the intake finishes, several at a time.
    public func run(_ intake: some EventIntake) async {
        await withTaskGroup(of: Void.self) { group in
            for await event in intake.events() {
                group.addTask { await self.handle(event) }
            }
        }
    }

    /// Logs the event, runs its hooks and logs how each one went.
    public func handle(_ event: HookEvent) async {
        record(.eventReceived(event))
        let hooks = config.hooks.filter { $0.on == event.event }
        guard !hooks.isEmpty else {
            record(.noHooks(eventID: event.id))
            return
        }
        _ = await runner.run(hooks, for: event, timeoutSeconds: config.timeoutSeconds) { progress in
            switch progress {
            case .started(let hookLine, let pid):
                self.record(.hookStarted(eventID: event.id, hookLine: hookLine, pid: pid))
            case .finished(let result):
                self.record(.hookFinished(eventID: event.id, result))
            }
        }
    }

    private func record(_ record: LogRecord) {
        do {
            try log.append(record)
        } catch {
            reportLogFailure(error)
        }
    }

    public static let printLogFailure: @Sendable (Error) -> Void = { error in
        FileHandle.standardError.write(Data("netshield daemon: event log write failed: \(error)\n".utf8))
    }
}
