import Foundation

/// Where the daemon's events come from: connections the extension paused in ask mode.
///
/// NetshieldXPC.XPCEventIntake implements this over XPC from the extension, checking the
/// extension's code signature and every event (`Messages.decode`). Tests provide their own.
/// Do not back it with a socket, a file or anything else another local process could write to:
/// a forged event would make the daemon run hooks with data the attacker chose.
public protocol EventIntake: Sendable {
    func events() -> AsyncStream<HookEvent>
}

/// Where `netshield daemon` keeps its files.
public enum DaemonPaths {
    /// The JSONL event log, in a private directory under ~/Library/Logs.
    public static func eventLog(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/netshield", isDirectory: true).appendingPathComponent("events.jsonl")
    }

    /// The private directory for the hooks' per-event directories, under the user's own temporary
    /// directory.
    public static func hookDirectory(temporary: URL) -> URL {
        temporary.appendingPathComponent("netshield-hooks", isDirectory: true)
    }
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

    /// The extension reported how a paused connection ended.
    public func recordVerdict(eventID: String, _ verdict: Verdict) {
        record(.verdict(eventID: eventID, verdict))
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
