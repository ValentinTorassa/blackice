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
}

/// The hooks and the timeout the daemon runs with. They come only from the configuration the
/// extension holds, the one `blackice start` and `blackice mode` saved after Touch ID, and never
/// from a file: any program of the user can start `blackice daemon`, but it cannot choose the
/// hooks that daemon runs.
public struct DaemonConfiguration: Equatable, Sendable {
    public let generation: UInt64
    /// The whole blackice.toml, parsed with the strict parser. The daemon uses its hooks and timeout.
    public let config: BlackiceConfig

    public init(generation: UInt64, configText: String) throws {
        guard generation > 0 else { throw ProviderConfigurationError("generation must be at least 1") }
        self.generation = generation
        config = try BlackiceConfig(text: configText)
    }

    public var hooks: [Hook] { config.hooks }
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
/// log. It does not decide anything itself; the answers go from the hooks to the extension
/// through `blackice approve` and `deny`.
public final class Daemon: Sendable {
    public let log: EventLog
    public let runner: HookRunner
    private let reportLogFailure: @Sendable (Error) -> Void

    /// `reportLogFailure` is called for every record the log could not take. The default prints
    /// to stderr, which the LaunchAgent sends to its own file.
    public init(log: EventLog, runner: HookRunner,
                reportLogFailure: @escaping @Sendable (Error) -> Void = Daemon.printLogFailure) {
        self.log = log
        self.runner = runner
        self.reportLogFailure = reportLogFailure
    }

    /// Handles events until the intake finishes, several at a time.
    public func run(_ intake: some EventIntake) async {
        let store = ConfigurationStore(fetch: { try await intake.configuration() },
                                       loaded: { configuration in self.record(.configurationLoaded(configuration)) })
        await withTaskGroup(of: Void.self) { group in
            for await message in intake.messages() {
                switch message {
                case .registered(let configuration):
                    await store.offer(configuration)
                case .event(let event, let generation):
                    group.addTask { await self.handle(event, generation: generation, store: store) }
                }
            }
        }
    }

    /// Logs the event, then runs the hooks of the configuration of the event's generation. When
    /// that configuration cannot be had, no hook runs, and with no answer the extension denies the
    /// connection at its deadline.
    public func handle(_ event: HookEvent, generation: UInt64, store: ConfigurationStore) async {
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
        await runHooks(for: event, configuration)
    }

    /// Logs the event, runs the configuration's hooks for it and logs how each one went.
    public func handle(_ event: HookEvent, with configuration: DaemonConfiguration) async {
        record(.eventReceived(event))
        await runHooks(for: event, configuration)
    }

    private func runHooks(for event: HookEvent, _ configuration: DaemonConfiguration) async {
        let hooks = configuration.hooks.filter { $0.on == event.event }
        guard !hooks.isEmpty else {
            record(.noHooks(eventID: event.id))
            return
        }
        _ = await runner.run(hooks, for: event, timeoutSeconds: configuration.timeoutSeconds) { progress in
            switch progress {
            case .queued(let hookLine, let waiting):
                self.record(.hookQueued(eventID: event.id, hookLine: hookLine, waiting: waiting))
            case .started(let hookLine, let pid, let waited):
                self.record(.hookStarted(eventID: event.id, hookLine: hookLine, pid: pid, waited: waited))
            case .finished(let result):
                self.record(.hookFinished(eventID: event.id, result))
            }
        }
    }

    /// The extension reported how a paused connection ended. Its hooks that still wait for a slot
    /// have nothing left to decide and are dropped.
    public func recordVerdict(eventID: String, _ verdict: Verdict) {
        record(.verdict(eventID: eventID, verdict))
        runner.eventEnded(eventID)
    }

    private func record(_ record: LogRecord) {
        do {
            try log.append(record)
        } catch {
            reportLogFailure(error)
        }
    }

    public static let printLogFailure: @Sendable (Error) -> Void = { error in
        FileHandle.standardError.write(Data("blackice daemon: event log write failed: \(error)\n".utf8))
    }
}
