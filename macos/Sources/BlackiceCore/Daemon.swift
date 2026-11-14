import Darwin
import Foundation

/// What the extension sends the daemon, in the order the intake receives it.
public enum IntakeMessage: Sendable {
    /// The extension accepted the registration and sent the configuration it holds.
    case registered(DaemonConfiguration)
    /// A paused connection, with the generation of the configuration the extension held when it
    /// sent the event.
    case event(HookEvent, generation: UInt64)
}

/// Where the daemon's events and configuration come from: the extension.
///
/// BlackiceXPC.XPCEventIntake implements this over XPC from the extension, checking the
/// extension's code signature and every message (`Messages.decode`). Tests provide their own.
/// Do not back it with a socket, a file or anything else another local process could write to:
/// a forged event would make the daemon run hooks with data the attacker chose, and a forged
/// configuration would make it run the attacker's hooks.
public protocol EventIntake: Sendable {
    /// Registers with the extension and yields the configuration it sends back, then the events.
    /// Finishes when the connection ends.
    func messages() -> AsyncStream<IntakeMessage>
    /// Asks the extension again for the configuration it holds now.
    func configuration() async throws -> DaemonConfiguration
    /// Sends a hook's answer, with the event's token, on the same connection. The extension takes
    /// an answer with a token only from the daemon it registered.
    func answer(_ request: AnswerRequest) async throws -> AnswerReply
}

/// Where the daemon sends a hook's answer: to the extension, through `EventIntake.answer`.
public typealias AnswerSender = @Sendable (AnswerRequest) async throws -> AnswerReply

/// The extension did not reply to an answer within `seconds`. Unlike a connection that is gone
/// (`unreachable`), the answer may still have been taken, late: it is logged as `reply_timeout`.
public struct AnswerReplyTimeout: Error, CustomStringConvertible {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) { self.seconds = seconds }

    public var description: String { "the network extension did not reply to the answer within \(Int(seconds)) s" }
}

/// Writes one line of the daemon's own to stderr (or `handle`), which the LaunchAgent sends to
/// daemon.err.log, after the time in UTC to the millisecond and the daemon's PID, so that it can
/// be put beside the event log and the system log, and told from the lines of the daemon before:
/// `2026-11-14T21:03:04.123Z [82988] blackice daemon: …`. A write that fails is dropped:
/// `FileHandle.write(_:)` raises an Objective-C exception for one (a full disk, a closed pipe),
/// which ends the process, and a daemon that cannot say a line should go on answering.
public func daemonLine(_ text: String, to handle: FileHandle = .standardError, at date: Date = Date()) {
    try? handle.write(contentsOf: Data((daemonLinePrefix(at: date, pid: getpid()) + text + "\n").utf8))
}

func daemonLinePrefix(at date: Date, pid: pid_t) -> String {
    "\(EventLog.timestamp(date)) [\(pid)] blackice daemon: "
}

/// The hooks and the timeout the daemon runs with. They come only from the configuration the
/// extension holds, the one `blackice start` and `blackice mode` saved after Touch ID, and never
/// from a file: any program of the user can start `blackice daemon`, but it cannot choose the
/// hooks that daemon runs.
public struct DaemonConfiguration: Equatable, Sendable {
    public let generation: UInt64
    /// The whole blackice.toml, parsed with the strict parser. The daemon uses its hooks (those
    /// `answers` in [agent] leaves running) and its timeout.
    public let config: BlackiceConfig

    public init(generation: UInt64, configText: String) throws {
        guard generation > 0 else { throw ProviderConfigurationError("generation must be at least 1") }
        self.generation = generation
        config = try BlackiceConfig(text: configText)
    }

    public var hooks: [Hook] { config.activeHooks }
    public var timeoutSeconds: Int { config.timeoutSeconds }

    public var summary: String {
        let count = hooks.count == 1 ? "1 hook" : "\(hooks.count) hooks"
        return "generation \(generation), \(count), timeout \(timeoutSeconds) s"
    }
}

/// The configuration the daemon holds. When an event names another generation, the daemon asks
/// the extension again rather than trusting the event or keeping old hooks; an older generation
/// never replaces a newer one.
public actor ConfigurationStore {
    private var held: DaemonConfiguration?
    private var fetching: Task<DaemonConfiguration, Error>?
    private let fetch: @Sendable () async throws -> DaemonConfiguration
    private let loaded: @Sendable (DaemonConfiguration) -> Void

    /// `fetch` asks the extension for its configuration; `loaded` is told about each one the
    /// store takes.
    public init(fetch: @escaping @Sendable () async throws -> DaemonConfiguration,
                loaded: @escaping @Sendable (DaemonConfiguration) -> Void = { _ in }) {
        self.fetch = fetch
        self.loaded = loaded
    }

    public var current: DaemonConfiguration? { held }

    /// Takes a configuration from the extension, unless the store holds a newer one. Returns the
    /// configuration held afterwards.
    @discardableResult
    public func offer(_ configuration: DaemonConfiguration) -> DaemonConfiguration {
        if let held, held.generation >= configuration.generation { return held }
        held = configuration
        loaded(configuration)
        return configuration
    }

    /// The configuration for an event of `generation`: the one held when it matches, otherwise the
    /// newest the extension has. A fetch already under way is joined; if it brings another
    /// generation (it may have started before the change), one more fetch follows. The result can
    /// still be another generation when the configuration changed again; the caller checks.
    public func configuration(for generation: UInt64) async throws -> DaemonConfiguration {
        if let held, held.generation == generation { return held }
        if let fetching {
            let joined = try await result(of: fetching)
            if joined.generation == generation { return joined }
        }
        return try await result(of: fetching ?? startFetch())
    }

    private func startFetch() -> Task<DaemonConfiguration, Error> {
        let task = Task { [fetch] in try await fetch() }
        fetching = task
        return task
    }

    private func result(of task: Task<DaemonConfiguration, Error>) async throws -> DaemonConfiguration {
        defer { if fetching == task { fetching = nil } }
        return offer(try await task.value)
    }
}

/// The user the daemon runs as, read from the user database and from confstr, never from the
/// environment, which whoever started the process chose.
public struct UserAccount: Equatable, Sendable {
    public let uid: uid_t
    public let name: String
    /// The home directory from the user database.
    public let home: String
    /// The per-user temporary directory, confstr(_CS_DARWIN_USER_TEMP_DIR), as macOS spells it
    /// (with a trailing slash).
    public let temporaryDirectory: String

    public init(uid: uid_t, name: String, home: String, temporaryDirectory: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && $0 != "=" && $0 != "/" }) else {
            throw FileSafetyError("user name", "is empty or not a plain name")
        }
        for (label, path) in [("home directory", home), ("temporary directory", temporaryDirectory)] {
            guard path.hasPrefix("/"), path.utf8.count <= Int(PATH_MAX),
                  !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw FileSafetyError(label, "must be an absolute path without control characters")
            }
        }
        self.uid = uid
        self.name = name
        self.home = home
        self.temporaryDirectory = temporaryDirectory
    }

    public var homeURL: URL { URL(fileURLWithPath: home, isDirectory: true) }
    public var temporaryURL: URL { URL(fileURLWithPath: temporaryDirectory, isDirectory: true) }

    /// The real user ID's entry in the user database (getpwuid_r), and its temporary directory.
    public static func current() throws -> UserAccount {
        let uid = getuid()
        let size = 16_384
        let entry: (name: String, home: String)? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: size) { buffer in
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard let base = buffer.baseAddress, getpwuid_r(uid, &record, base, size, &result) == 0, result != nil,
                  let name = record.pw_name, let home = record.pw_dir else { return nil }
            return (String(cString: name), String(cString: home))
        }
        guard let entry else { throw FileSafetyError("uid \(uid)", "has no entry in the user database") }
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { throw FileSafetyError("_CS_DARWIN_USER_TEMP_DIR", "confstr failed: \(errnoText(errno))") }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else {
            throw FileSafetyError("_CS_DARWIN_USER_TEMP_DIR", "confstr failed: \(errnoText(errno))")
        }
        let temporary = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return try UserAccount(uid: uid, name: entry.name, home: entry.home, temporaryDirectory: temporary)
    }
}

/// Where `blackice daemon` keeps its files. Callers pass the directories from `UserAccount`.
public enum DaemonPaths {
    /// ~/Library/Logs/blackice, private (0700): the event log, and launchd's copies of the
    /// daemon's stdout and stderr.
    public static func logDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/blackice", isDirectory: true)
    }

    /// The JSONL event log.
    public static func eventLog(home: URL) -> URL {
        logDirectory(home: home).appendingPathComponent("events.jsonl")
    }

    /// The private directory for the hooks' per-event directories, under the user's own temporary
    /// directory.
    public static func hookDirectory(temporary: URL) -> URL {
        temporary.appendingPathComponent("blackice-hooks", isDirectory: true)
    }
}

/// The user-level side of blackice: takes paused connections from the intake, runs the hooks
/// of the configuration the extension holds for each one, and records everything in the event
/// log. It does not decide anything itself. A hook answers on its stdout (`HookAnswer`), and the
/// daemon sends that answer to the extension for the event's app and host, with the event's
/// token, which no hook ever gets.
public final class Daemon: Sendable {
    public let log: EventLog
    public let runner: HookRunner
    private let reportLogFailure: @Sendable (Error) -> Void
    private let failures = FailureRun()

    /// `reportLogFailure` is called for every record the log could not take. The default prints
    /// to stderr, which the LaunchAgent sends to its own file.
    public init(log: EventLog, runner: HookRunner,
                reportLogFailure: @escaping @Sendable (Error) -> Void = Daemon.printLogFailure) {
        self.log = log
        self.runner = runner
        self.reportLogFailure = reportLogFailure
    }

    /// Handles events until the intake finishes, several at a time. The group discards each
    /// event's task as it ends: a plain task group keeps finished ones until they are collected,
    /// and this one lasts as long as the daemon. It returns once every event's task has ended.
    ///
    /// With `stopHooksWhenIntakeEnds`, as `blackice daemon` runs it, the end of the intake stops
    /// the hooks (`HookRunner.stopAll`), so that it returns within the grace period: the extension
    /// that sent their events is gone, and with it their tokens. Up to 1.0.7 it waited for each
    /// hook to end on its own or at its timeout, and launchd could not start the next daemon
    /// meanwhile, so the restarted extension's events found none (`event_not_sent no_daemon`).
    public func run(_ intake: some EventIntake, stopHooksWhenIntakeEnds: Bool = false) async {
        let store = ConfigurationStore(fetch: { try await intake.configuration() },
                                       loaded: { configuration in self.record(.configurationLoaded(configuration)) })
        await withDiscardingTaskGroup { group in
            for await message in intake.messages() {
                switch message {
                case .registered(let configuration):
                    await store.offer(configuration)
                case .event(let event, let generation):
                    group.addTask {
                        await self.handle(event, generation: generation, store: store) { try await intake.answer($0) }
                    }
                }
            }
            if stopHooksWhenIntakeEnds { runner.stopAll() }
        }
    }

    /// Logs the event, then runs the hooks of the configuration of the event's generation and
    /// sends their answers with `send`. When that configuration cannot be had, no hook runs, and
    /// with no answer the extension denies the connection at its deadline.
    public func handle(_ event: HookEvent, generation: UInt64, store: ConfigurationStore, send: @escaping AnswerSender) async {
        record(.eventReceived(event))
        let configuration: DaemonConfiguration
        do {
            configuration = try await store.configuration(for: generation)
        } catch {
            record(.hooksSkipped(eventID: event.id, reason: "configuration_unavailable"))
            return
        }
        guard configuration.generation == generation else {
            // The extension holds another configuration now. Installing it dropped every paused
            // connection, this event's included, so its token is already dead.
            record(.hooksSkipped(eventID: event.id, reason: "configuration_changed"))
            return
        }
        await runHooks(for: event, configuration, send: send)
    }

    /// Logs the event, runs the configuration's hooks for it, logs how each one went and sends
    /// their answers with `send`.
    public func handle(_ event: HookEvent, with configuration: DaemonConfiguration, send: @escaping AnswerSender) async {
        record(.eventReceived(event))
        await runHooks(for: event, configuration, send: send)
    }

    private func runHooks(for event: HookEvent, _ configuration: DaemonConfiguration, send: @escaping AnswerSender) async {
        let hooks = configuration.hooks.filter { $0.on == event.event }
        guard !hooks.isEmpty else {
            record(.noHooks(eventID: event.id))
            return
        }
        // One task per hook, so each answer goes out as soon as its hook is done. With several
        // hooks the first answer counts; the token is spent then, and later ones are refused.
        await withTaskGroup(of: Void.self) { group in
            for hook in hooks {
                group.addTask {
                    let results = await self.runner.run([hook], for: event, timeoutSeconds: configuration.timeoutSeconds,
                                                        notes: configuration.config.agentNotes) { progress in
                        switch progress {
                        case .queued(let hookLine, let waiting):
                            self.record(.hookQueued(eventID: event.id, hookLine: hookLine, waiting: waiting))
                        case .started(let hookLine, let pid, let waited):
                            self.record(.hookStarted(eventID: event.id, hookLine: hookLine, pid: pid, waited: waited))
                        case .finished(let result):
                            self.record(.hookFinished(eventID: event.id, result))
                        }
                    }
                    for result in results { await self.deliver(result, for: event, send: send) }
                }
            }
        }
    }

    /// Logs what a hook that ran answered, and sends the answer.
    private func deliver(_ result: HookResult, for event: HookEvent, send: AnswerSender) async {
        switch result.answer {
        case nil:
            return
        case .failure(let missing)?:
            var previous: String?
            if case .output(.unrecognized) = missing { previous = HookAnswer.previousLinePrefix(result.stdout) }
            let now = Date()
            record(.hookNoAnswer(eventID: event.id, hookLine: result.hookLine, missing, previousPrefix: previous), at: now)
            if Self.failed(missing) { countFailure(missing.reason, stderr: result.stderr, at: now) }
        case .success(let answer)?:
            record(.hookAnswered(eventID: event.id, hookLine: result.hookLine, answer))
            countAnswer()
            guard let request = Self.request(answer, for: event) else {
                record(.answerRefused(eventID: event.id, hookLine: result.hookLine, reason: "invalid_event"))
                return
            }
            let reason: String
            do {
                let reply = try await send(request)
                guard reply.status != .done else { return }
                reason = reply.reason
            } catch {
                reason = error is AnswerReplyTimeout ? "reply_timeout" : "unreachable"
                daemonLine("the answer of hook line \(result.hookLine) for event \(event.id) was not taken: \(error)")
            }
            record(.answerRefused(eventID: event.id, hookLine: result.hookLine, reason: reason))
        }
    }

    // MARK: - Hooks failing in a row

    /// Whether a hook that ran and gave no answer failed by itself: it exited with another status,
    /// died of a signal of its own, or printed no answer. Not when it ran out of time, which a busy
    /// queue or a sleep causes, nor when its home changed while it ran.
    static func failed(_ missing: HookResult.NoAnswer) -> Bool {
        switch missing {
        case .exitStatus, .signaled, .output: return true
        case .deadline, .unsafeHome: return false
        }
    }

    /// The counts at which `hooks_failing` is written: 3, 10, 30, 100, 300, 1000 and so on, often
    /// at first and ever less after, so that an agent that stays broken does not fill the log.
    static func isMilestone(_ count: Int) -> Bool {
        guard count >= 3 else { return false }
        var rest = count
        while rest % 10 == 0 { rest /= 10 }
        return rest == 3 || (rest == 1 && count >= 10)
    }

    /// The first line of a hook's stderr with something in it, without control characters and cut
    /// to 200 characters: an agent that cannot run mostly says why there (a login that expired, a
    /// model that is not there). Empty when it wrote nothing.
    static func firstLine(_ stderr: String) -> String {
        for line in stderr.split(whereSeparator: \.isNewline) {
            let kept = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.properties.generalCategory != .control }))
                .trimmingCharacters(in: .whitespaces)
            if !kept.isEmpty { return String(kept.prefix(200)) }
        }
        return ""
    }

    /// One more hook failed. Every hook may be failing the same way, such as an agent whose login
    /// expired, and the log then holds only a `hook_no_answer` per event: the run's count, its
    /// latest reason and what its hook said first go in a record of their own, which `blackice
    /// status` and the menu show. Nothing stops the hooks; the next event runs them as always.
    private func countFailure(_ reason: String, stderr: String, at date: Date) {
        failures.lock.lock()
        defer { failures.lock.unlock() }
        if failures.count == 0 { failures.since = date }
        failures.count += 1
        guard Self.isMilestone(failures.count) else { return }
        record(.hooksFailing(count: failures.count, reason: reason, stderrLine: Self.firstLine(stderr),
                             since: failures.since ?? date))
    }

    /// A hook answered: the run of failures is over, and when it was long enough to be written,
    /// that it ended is written too.
    private func countAnswer() {
        failures.lock.lock()
        defer { failures.lock.unlock() }
        if failures.count >= 3 { record(.hooksRecovered(after: failures.count)) }
        failures.count = 0
        failures.since = nil
    }

    /// The answer as the extension takes it: for the event's app and host, never anything from the
    /// hook, with the event's token. nil for an event with no host, which nothing can answer.
    static func request(_ answer: HookAnswer, for event: HookEvent) -> AnswerRequest? {
        guard let identity = event.app.identity, let host = event.host else { return nil }
        switch answer {
        case .approve(let seconds):
            return AnswerRequest(kind: .approve, app: identity, host: host, seconds: seconds, token: event.token)
        case .deny:
            return AnswerRequest(kind: .deny, app: identity, host: host, seconds: nil, token: event.token)
        }
    }

    /// The extension reported how a paused connection ended. Its hooks that still wait for a slot
    /// have nothing left to decide and are dropped.
    public func recordVerdict(eventID: String, _ verdict: Verdict) {
        record(.verdict(eventID: eventID, verdict))
        runner.eventEnded(eventID)
    }

    private func record(_ record: LogRecord, at date: Date = Date()) {
        do {
            try log.append(record, at: date)
        } catch {
            reportLogFailure(error)
        }
    }

    public static let printLogFailure: @Sendable (Error) -> Void = { error in
        daemonLine("event log write failed: \(error)")
    }
}

/// The hooks in a row that failed (`Daemon.failed`), with no answer between them. Kept in memory
/// only: a daemon that starts again counts afresh.
private final class FailureRun: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    /// When the first of them ended.
    var since: Date?
}
