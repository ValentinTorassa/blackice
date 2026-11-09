import Darwin
import Foundation
import LightweightCodeRequirements

// Runs the [[hook]] commands for one event.
//
// What runs comes from blackice.toml, which the user wrote and the strict parser accepted: a
// `program`, started directly with its `args`, or a `run` line, started as `/bin/sh -c RUN`.
// Nothing from the event is ever put into a command line. A program is started with a launch
// requirement built from its hook's `app` and `team` (`launchRequirement(for:)`): the kernel
// checks the code during exec and kills it before its first instruction when it does not match,
// so a program swapped for another, or one that another program of the user stops and lets run
// first, never gets to answer. Once it runs, its code signature is checked again by its PID, and
// the hook is refused (`refused`) when either check fails. The kernel checks only the code the
// hook starts: a program that starts another in its place (exec) is refused when the second check
// sees the other one, and may be let through when it comes too late, so a hook names the agent's
// own executable, never a wrapper. Apple's own code that starts other Apple code, as /bin/sh
// starts bash, passes. A `run` line has no check. With SIP off the kernel checks no launch
// requirement (`kernelChecksLaunch`): the check by PID is then the only one, a hook that exits
// before it is refused, and a program that starts the agent in its own place before it may pass.
//
// A program hook that names its agent's instructions (`instructions = "codex"`) gets no files. The
// event, without its token, comes as JSON on stdin; the instructions and the owner's notes come in
// the agent's flags or environment (AgentInstructions.launch); it runs in /var/empty, which
// belongs to root. Up to 1.0.2 all of them were files the user owns, which any program of the user
// could rewrite while the agent read them. opencode alone also gets a new private folder for its
// configuration. Before such a hook starts and again once it exits, its agent's home is checked
// for files the agent would load as instructions (AgentInstructions.plantedFile): one found before
// means the hook does not start (`unsafeHome`), one found after means its answer does not count.
//
// Any other hook, a `run` line or a program that names no instructions, gets what it got in 1.0,
// since blackice cannot know what it reads: the event on stdin (for a program, unless its hook
// says `stdin = "none"`), and the same bytes in a 0600 file inside a private 0700 directory, named
// in BLACKICE_EVENT_FILE, with the owner's notes from [agent] as notes.md beside it. It runs in
// that directory, which is deleted once it is done. Every hook gets the event's ID in
// BLACKICE_EVENT_ID. The token never reaches a hook. The hook answers on stdout (see HookAnswer):
// the runner keeps the first `stdoutLimit` bytes and the first `stderrLimit` bytes of stderr, and
// drains the rest.
//
// Hooks are started with Process, which on macOS puts the child in a process group of its own,
// passes it only stdin, stdout and stderr, and gives it every signal at its default with none
// blocked (HookRunnerTests checks all three). At the deadline the group gets SIGTERM and, after a
// grace period, SIGKILL. When the hook exits, whatever it left behind in its group is killed too.
// A process that leaves the group on purpose (setsid, setpgid) escapes this.
//
// At most `maximumConcurrent` hooks run at once. A hook that finds no free slot waits for one,
// without holding a thread. Waiting hooks take turns between apps, first come first served
// within an app, so one app that opens many connections at once cannot crowd out the rest (on
// 3 November 2026 Tailscale's network extension sent 316 of 905 events). A waiting hook is
// dropped when less than `minimumStartBudget` of its time is left (`deadline_near`), when its
// event ends while it waits (`event_ended`), and when `maximumWaiting` hooks already wait
// (`queue_full`). A dropped hook's connection is denied when its timeout passes, unless
// something else answers it.

public struct HookResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The shell exited on its own, with this status.
        case exited(status: Int32)
        /// The shell died from a signal that blackice did not send.
        case signaled(signal: Int32)
        /// The deadline passed and blackice killed the hook's process group. The signal is the one
        /// that ended the shell: SIGTERM, or SIGKILL after the grace period.
        case timedOut(signal: Int32)
        /// The hook was not started.
        case dropped(DropReason)
        /// The program could not be started, or the event's file or folder could not be made.
        case failedToStart(String)
        /// The program's code signature did not name its hook's app and team: the kernel did not
        /// start it, or it was killed as soon as the check after its start saw what it was. `found`
        /// is what it was (`IdentityResolution.label`, or the file's identity when the running code
        /// could not be read).
        case refused(found: String)
        /// The agent's home holds a file the agent would load as instructions, which blackice did
        /// not put there (`AgentInstructions.plantedFile`), so the hook was not started.
        case unsafeHome(path: String)
    }

    public enum DropReason: String, Equatable, Sendable {
        /// The event's deadline had passed when its hook came to run.
        case deadlinePassed = "deadline_passed"
        /// The hook waited for a slot until less than `minimumStartBudget` of its time was left.
        case deadlineNear = "deadline_near"
        /// The extension reported how the event's connection ended while the hook waited.
        case eventEnded = "event_ended"
        /// `maximumWaiting` hooks were already waiting for a slot.
        case queueFull = "queue_full"
        case invalidEventID = "invalid_event_id"
    }

    /// Line of the hook's [[hook]] header in blackice.toml; identifies the hook.
    public let hookLine: Int
    public let outcome: Outcome
    /// The first `stderrLimit` bytes the hook wrote to stderr, decoded as UTF-8 with replacement.
    public let stderr: String
    public let stderrTruncated: Bool
    /// The first `stdoutLimit` bytes the hook wrote to stdout, where it answers.
    public let stdout: Data
    public let stdoutTruncated: Bool
    /// From the hook's start, or from when it was dropped; the time it waited is not included.
    public let duration: TimeInterval
    /// How long the hook waited for a slot; 0 when one was free.
    public let waited: TimeInterval
    /// A file the agent would load as instructions that was in its home once the hook exited,
    /// though not before it started: whatever the hook answered does not count.
    public let unsafeHome: String?

    public init(hookLine: Int, outcome: Outcome, stderr: String, stderrTruncated: Bool, duration: TimeInterval,
                waited: TimeInterval = 0, stdout: Data = Data(), stdoutTruncated: Bool = false, unsafeHome: String? = nil) {
        self.hookLine = hookLine
        self.outcome = outcome
        self.stderr = stderr
        self.stderrTruncated = stderrTruncated
        self.stdout = stdout
        self.stdoutTruncated = stdoutTruncated
        self.duration = duration
        self.waited = waited
        self.unsafeHome = unsafeHome
    }

    /// The hook's answer, or why it has none. nil when the hook did not run (dropped, failed to
    /// start or refused), which its own record says. An answer counts only from a hook that
    /// exited with status 0 before its deadline, with its agent's home as it was when it started.
    public var answer: Result<HookAnswer, HookResult.NoAnswer>? {
        switch outcome {
        case .dropped, .failedToStart, .refused, .unsafeHome: return nil
        case .exited, .signaled, .timedOut: break
        }
        if let unsafeHome { return .failure(.unsafeHome(unsafeHome)) }
        switch outcome {
        case .exited(let status) where status == 0:
            return HookAnswer.parse(stdout, truncated: stdoutTruncated).mapError { .output($0) }
        case .exited(let status): return .failure(.exitStatus(status))
        case .signaled(let signal): return .failure(.signaled(signal))
        case .timedOut: return .failure(.deadline)
        case .dropped, .failedToStart, .refused, .unsafeHome: return nil
        }
    }

    /// Why a hook that ran gave no answer.
    public enum NoAnswer: Error, Equatable, Sendable {
        case exitStatus(Int32)
        case signaled(Int32)
        /// Killed at the deadline.
        case deadline
        /// It exited with status 0, but its output holds no answer.
        case output(HookAnswer.Missing)
        /// This file, which the agent would load as instructions, was in its home once it exited.
        case unsafeHome(String)

        public var reason: String {
            switch self {
            case .exitStatus: return "exit_status"
            case .signaled: return "signaled"
            case .deadline: return "deadline"
            case .output(let missing): return missing.reason
            case .unsafeHome: return "agent_home"
            }
        }
    }
}

public enum HookProgress: Sendable {
    /// No slot was free: the hook waits, with `waiting` hooks waiting now, itself included.
    case queued(hookLine: Int, waiting: Int)
    /// `waited` is how long it waited for a slot; 0 when one was free.
    case started(hookLine: Int, pid: Int32, waited: TimeInterval)
    case finished(HookResult)
}

public final class HookRunner: @unchecked Sendable {
    public struct Options: Sendable {
        /// Private directory (0700) for the per-hook event directories. Created if missing.
        public var workDirectory: URL
        /// The whole environment a hook starts with, apart from the BLACKICE_ variables.
        /// Build it with `HookRunner.environment(for:)`; nothing is inherited from the daemon.
        public var environment: [String: String]
        public var maximumConcurrent: Int
        /// Hooks waiting for a slot, at most; the extension holds at most 256 events at once.
        public var maximumWaiting: Int
        /// A hook that waited starts only with this much time left (or the whole timeout, when that
        /// is shorter). fx takes 10 to 27 s to answer; a hook started with less is mostly killed.
        public var minimumStartBudget: TimeInterval
        /// Time between SIGTERM and SIGKILL.
        public var gracePeriod: TimeInterval
        public var stderrLimit: Int
        public var stdoutLimit: Int
        /// The identity of a program hook just after it started, before its stdin is written.
        /// Tests replace it.
        public var identify: @Sendable (pid_t) -> IdentityResolution
        /// A file in the agent's home that it would load as instructions, given the program and the
        /// environment it runs with; nil when there is none. Tests replace it.
        public var unsafeHome: @Sendable (HookProgram, [String: String]) -> String?
        /// Whether the kernel checks a launch requirement on this Mac. Tests replace it.
        public var kernelChecksLaunch: @Sendable () -> Bool
        /// The time of day, which counts the time the Mac sleeps, as an event's deadline does. A
        /// hook's own timeout is measured in time awake. Tests replace it to stand for a sleep.
        public var wallClock: @Sendable () -> Date

        public init(workDirectory: URL, environment: [String: String], maximumConcurrent: Int = 4,
                    maximumWaiting: Int = 256, minimumStartBudget: TimeInterval = 10,
                    gracePeriod: TimeInterval = 2, stderrLimit: Int = 4096,
                    stdoutLimit: Int = HookAnswer.maximumOutputBytes,
                    identify: @escaping @Sendable (pid_t) -> IdentityResolution = { CodeIdentity.resolve(childPID: $0) },
                    unsafeHome: @escaping @Sendable (HookProgram, [String: String]) -> String? = {
                        $0.instructions?.plantedFile(environment: $1)
                    },
                    kernelChecksLaunch: @escaping @Sendable () -> Bool = { HookRunner.kernelChecksLaunch },
                    wallClock: @escaping @Sendable () -> Date = { Date() }) {
            self.workDirectory = workDirectory
            self.environment = environment
            self.maximumConcurrent = maximumConcurrent
            self.maximumWaiting = maximumWaiting
            self.minimumStartBudget = minimumStartBudget
            self.gracePeriod = gracePeriod
            self.stderrLimit = stderrLimit
            self.stdoutLimit = stdoutLimit
            self.identify = identify
            self.unsafeHome = unsafeHome
            self.kernelChecksLaunch = kernelChecksLaunch
            self.wallClock = wallClock
        }
    }

    public static let shell = "/bin/sh"
    /// launchd's PATH for agents. A hook that needs more sets PATH in its `env` or its `run` line.
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let language = "en_US.UTF-8"
    /// Where program hooks run: empty, and root's, so nothing there was put by a program of the user.
    public static let programDirectory = "/var/empty"

    /// What the kernel requires of a program hook's code before it runs a single instruction: the
    /// hook's signing identifier and Team ID with a Developer ID signature, or, with no Team ID,
    /// the signing identifier of Apple platform code. Code signed any other way (Apple Development,
    /// the Mac App Store, ad hoc) does not start, though up to 1.0.2 the check after a suspended
    /// start took some of it.
    public static func launchRequirement(for identity: SigningIdentity) throws -> LaunchCodeRequirement {
        guard let team = identity.teamID else {
            return try LaunchCodeRequirement.allOf {
                SigningIdentifier(identity.signingID)
                ValidationCategory(.platform)
            }
        }
        return try LaunchCodeRequirement.allOf {
            TeamIdentifier(team)
            SigningIdentifier(identity.signingID)
            ValidationCategory(.developerID)
        }
    }

    /// Whether the kernel checks launch requirements here. It does not when SIP is off ("SIP is
    /// disabled, not checking launch constraints", AMFI says): the hook's code is then checked by
    /// its PID alone. Found once, the first time it matters, by starting /usr/bin/true under a
    /// requirement it does not meet: the kernel kills it, and macOS keeps a crash report of that.
    public static let kernelChecksLaunch: Bool = {
        let unmet = SigningIdentity(signingID: "com.valentorassa.blackice.launch-check", teamID: nil)
        guard let requirement = try? launchRequirement(for: unmet) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.arguments = []
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.launchRequirement = requirement
        guard (try? process.run()) != nil else { return false }
        let giveUp = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < giveUp else {
                _ = kill(process.processIdentifier, SIGKILL)
                return false
            }
            usleep(2_000)
        }
        return process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
    }()

    public let options: Options
    private let lock = NSLock()
    private var running = 0
    /// Hooks waiting for a slot, by app, oldest first. `turns` holds each app with a waiting hook
    /// once, in the order the next free slots go to them. While a hook waits every slot is taken:
    /// a slot that frees goes straight to the next waiting hook.
    private var waiting: [String: [Waiter]] = [:]
    private var turns: [String] = []
    private var waitingTotal = 0
    private var nextTicket: UInt64 = 0

    private struct Waiter {
        let ticket: UInt64
        let eventID: String
        /// Past this, less than the minimum start budget is left.
        let startBy: Date
        let continuation: CheckedContinuation<Admission, Never>
    }

    private enum Admission {
        case admitted
        case dropped(HookResult.DropReason)
    }

    public init(options: Options) throws {
        precondition(options.maximumConcurrent >= 1, "maximumConcurrent must be at least 1")
        precondition(options.maximumWaiting >= 0, "maximumWaiting must not be negative")
        try PrivateDirectory.ensure(options.workDirectory)
        self.options = options
    }

    /// The hook environment, built by the daemon rather than inherited from whoever started it:
    /// HOME, USER and LOGNAME from the user database, TMPDIR from confstr, a fixed PATH and LANG.
    /// The runner adds BLACKICE_EVENT_ID, and BLACKICE_EVENT_FILE for a hook that names no instructions.
    public static func environment(for account: UserAccount) -> [String: String] {
        ["HOME": account.home, "USER": account.name, "LOGNAME": account.name, "TMPDIR": account.temporaryDirectory,
         "PATH": defaultPath, "LANG": language]
    }

    /// Hooks running right now.
    public var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Hooks waiting for a slot right now.
    public var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waitingTotal
    }

    /// Runs `hooks` for `event` side by side and returns one result per hook, in file order.
    /// Each hook is killed at `event.deadline` or after `timeoutSeconds`, whichever comes first. The
    /// deadline counts the time the Mac sleeps and the timeout does not, so a hook the Mac slept
    /// through dies when it wakes past the deadline, and holds no slot for an event that is over.
    /// `notes`, the owner's notes for the agent from the configuration, go to a program hook with
    /// its instructions, and into the directory of any other hook as notes.md.
    public func run(_ hooks: [Hook], for event: HookEvent, timeoutSeconds: Int, notes: String? = nil,
                    progress: @escaping @Sendable (HookProgress) -> Void = { _ in }) async -> [HookResult] {
        await withTaskGroup(of: HookResult.self) { group in
            for hook in hooks {
                group.addTask {
                    let result = await self.runOne(hook, for: event, timeoutSeconds: timeoutSeconds, notes: notes,
                                                   progress: progress)
                    progress(.finished(result))
                    return result
                }
            }
            var results: [HookResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.hookLine < $1.hookLine }
        }
    }

    /// The extension reported how `eventID`'s connection ended: its hooks that still wait for a slot
    /// have nothing left to decide, and are dropped (`event_ended`). Running hooks are left alone.
    public func eventEnded(_ eventID: String) {
        lock.lock()
        var ended: [Waiter] = []
        for (app, list) in waiting where list.contains(where: { $0.eventID == eventID }) {
            ended += list.filter { $0.eventID == eventID }
            setWaiters(list.filter { $0.eventID != eventID }, of: app)
        }
        lock.unlock()
        ended.forEach { $0.continuation.resume(returning: .dropped(.eventEnded)) }
    }

    // MARK: - One hook

    private func runOne(_ hook: Hook, for event: HookEvent, timeoutSeconds: Int, notes: String?,
                        progress: @escaping @Sendable (HookProgress) -> Void) async -> HookResult {
        func dropped(_ reason: HookResult.DropReason, waited: TimeInterval = 0) -> HookResult {
            HookResult(hookLine: hook.line, outcome: .dropped(reason), stderr: "", stderrTruncated: false, duration: 0,
                       waited: waited)
        }
        guard Self.validEventID(event.id) else { return dropped(.invalidEventID) }
        guard min(event.deadline.timeIntervalSinceNow, TimeInterval(timeoutSeconds)) > 0 else {
            return dropped(.deadlinePassed)
        }
        let queuedAt = uptime()
        let needed = min(options.minimumStartBudget, TimeInterval(timeoutSeconds))
        let (admission, queued) = await admit(app: Self.appKey(event.app), eventID: event.id,
                                              startBy: event.deadline.addingTimeInterval(-needed)) { waitingNow in
            progress(.queued(hookLine: hook.line, waiting: waitingNow))
        }
        let waited = queued ? uptime() - queuedAt : 0
        if case .dropped(let reason) = admission { return dropped(reason, waited: waited) }
        // waitpid and the pipe reads block, so each hook gets its own thread instead of a thread
        // from the concurrency pool. A hook gets its thread only once it holds a slot.
        return await withCheckedContinuation { continuation in
            Thread {
                let result = self.runBlocking(hook, event: event, timeoutSeconds: timeoutSeconds, notes: notes,
                                              waited: waited, progress: progress)
                continuation.resume(returning: result)
            }.start()
        }
    }

    /// Runs one hook that holds a slot, and gives the slot back when it is done.
    private func runBlocking(_ hook: Hook, event: HookEvent, timeoutSeconds: Int, notes: String?, waited: TimeInterval,
                             progress: @Sendable (HookProgress) -> Void) -> HookResult {
        defer { releaseSlot() }
        let started = uptime()
        func finish(_ outcome: HookResult.Outcome, stderr: String = "", truncated: Bool = false,
                    stdout: Data = Data(), stdoutTruncated: Bool = false, unsafeHome: String? = nil) -> HookResult {
            HookResult(hookLine: hook.line, outcome: outcome, stderr: stderr, stderrTruncated: truncated,
                       duration: uptime() - started, waited: waited, stdout: stdout, stdoutTruncated: stdoutTruncated,
                       unsafeHome: unsafeHome)
        }

        let budget = min(event.deadline.timeIntervalSince(options.wallClock()), TimeInterval(timeoutSeconds))
        guard budget > 0 else { return finish(.dropped(.deadlinePassed)) }

        func usable(_ key: String, _ value: String) -> Bool {
            !key.hasPrefix("BLACKICE_") && !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }
        var environment = options.environment.filter(usable)
        // A folder of the hook's own: the event and the notes of a hook that names no instructions,
        // or opencode's configuration.
        var directory: URL?
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        let json: Data
        var eventOnStdin = true
        let start: (executable: String, arguments: [String], directory: String, requirement: LaunchCodeRequirement?)
        do {
            json = try event.input.jsonData()
            if let program = hook.program {
                environment.merge(program.environment.filter(usable)) { $1 }
                if let found = options.unsafeHome(program, environment) { return finish(.unsafeHome(path: found)) }
            }
            let requirement = try hook.program.map { try Self.launchRequirement(for: $0.identity) }
            if let program = hook.program, let instructions = program.instructions {
                var folder: String?
                if instructions.needsConfigurationFolder {
                    let made = try makeEventDirectory()
                    directory = made
                    let configuration = made.appendingPathComponent("opencode", isDirectory: true)
                    guard mkdir(configuration.path, 0o700) == 0 else {
                        throw FileSafetyError(configuration.path, "cannot create the folder: \(errnoText(errno))")
                    }
                    folder = made.path
                }
                let launch = instructions.launch(arguments: program.arguments, notes: notes, configurationFolder: folder)
                environment.merge(launch.environment.filter(usable)) { $1 }
                start = (program.path, launch.arguments, Self.programDirectory, requirement)
            } else {
                let made = try makeEventDirectory()
                directory = made
                let eventFile = made.appendingPathComponent("event.json")
                try writePrivateFile(eventFile, json)
                if let notes {
                    try writePrivateFile(made.appendingPathComponent("notes.md"), Data((notes.hasSuffix("\n") ? notes : notes + "\n").utf8))
                }
                environment["BLACKICE_EVENT_FILE"] = eventFile.path
                if let program = hook.program {
                    eventOnStdin = program.eventOnStdin
                    start = (program.path, program.arguments, made.path, requirement)
                } else {
                    start = (Self.shell, ["-c", hook.run ?? ""], made.path, nil)
                }
            }
        } catch {
            return finish(.failedToStart("\(error)"))
        }
        environment["BLACKICE_EVENT_ID"] = event.id

        let child: SpawnedHook
        do {
            child = try spawn(start.executable, start.arguments, environment: environment, directory: start.directory,
                              requirement: start.requirement)
        } catch {
            return finish(.failedToStart("\(error)"))
        }
        // Read from the start, so that a hook that writes much before the check below never blocks.
        let collector = OutputCollector(limit: options.stderrLimit)
        collector.start(reading: child.stderr)
        let answer = OutputCollector(limit: options.stdoutLimit)
        answer.start(reading: child.stdout)

        if let program = hook.program {
            // The kernel checked the code at exec. This checks it again, and refuses the hook when
            // the running code is another's, or cannot be read and does not exit on its own: code
            // the kernel would not start dies of SIGKILL before its first instruction, and its PID
            // names no valid code by then. A hook that already exited with a status of its own
            // cannot be read either, but it ran only because the kernel let it; it has not had the
            // event yet. Where the kernel does not check (SIP is off), that proves nothing, and the
            // hook is refused: a program put in its place could print an answer and exit before
            // this check.
            // Apple's own code may have started other Apple code in its place, as /bin/sh starts
            // bash: the kernel checked the first, and the system volume holds both. Apple code the
            // kernel refused can still read as itself for a moment before its SIGKILL lands, so that
            // case also waits to see it was not killed.
            let found = options.identify(child.pid)
            let otherCode = found.appIdentity != nil
            var expected = found == .verified(program.identity)
            if !expected, program.identity.teamID == nil, found.verifiedIdentity.map({ $0.teamID == nil }) == true {
                expected = !killedAtOnce(child)
            }
            if !expected, otherCode || !exitedOnItsOwn(child) || !options.kernelChecksLaunch() {
                _ = kill(-child.pid, SIGKILL)
                waitForTermination(child)
                close(child.stdin)
                collector.stop(after: 0)
                answer.stop(after: 0)
                _ = collector.finish()
                _ = answer.finishData()
                // What the file is, when the running code could not be read.
                let label = otherCode ? found.label : CodeIdentity.identity(atPath: program.path)?.label ?? found.label
                return finish(.refused(found: label))
            }
        }
        progress(.started(hookLine: hook.line, pid: child.pid, waited: waited))
        feed(eventOnStdin ? json : Data(), to: child.stdin)

        // `killAt` is in time awake. A sleep stops that clock but not the deadline's, so the time of
        // day is checked too: on 8 November 2026 four hooks the Mac slept through held every slot
        // for 12 minutes after their events had timed out, and the events after them got no hook.
        let killAt = started + budget
        var lastSignal: Int32?
        var termSentAt: TimeInterval = 0
        while !hasExited(child.pid) {
            let now = uptime()
            if lastSignal == nil, now >= killAt || options.wallClock() >= event.deadline {
                _ = kill(-child.pid, SIGTERM)
                lastSignal = SIGTERM
                termSentAt = now
            } else if lastSignal == SIGTERM, now >= termSentAt + options.gracePeriod {
                _ = kill(-child.pid, SIGKILL)
                lastSignal = SIGKILL
            }
            usleep(10_000)
        }
        // Anything the hook left running in its group goes with it. Process reaps the hook itself,
        // and may have done so already; the group's ID stays taken while any process is in it.
        _ = kill(-child.pid, SIGKILL)
        waitForTermination(child)

        collector.stop(after: 0.2)
        answer.stop(after: 0.2)
        let (stderr, truncated) = collector.finish()
        let (stdout, stdoutTruncated) = answer.finishData()

        let status = child.process.terminationStatus
        let killed = child.process.terminationReason == .uncaughtSignal
        let outcome: HookResult.Outcome
        if let lastSignal {
            outcome = .timedOut(signal: killed ? status : lastSignal)
        } else if killed {
            outcome = .signaled(signal: status)
        } else {
            outcome = .exited(status: status)
        }
        // A file that appeared in the agent's home while it ran voids its answer.
        let changed = hook.program.flatMap { options.unsafeHome($0, environment) }
        return finish(outcome, stderr: stderr, truncated: truncated, stdout: stdout, stdoutTruncated: stdoutTruncated,
                      unsafeHome: changed)
    }

    /// Event IDs end up in an environment variable and the log; only plain characters are accepted.
    static func validEventID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    // MARK: - Slots and the queue

    /// Turns are per app: its signing identity, or its cdhash when it is signed ad hoc.
    static func appKey(_ app: HookEvent.App) -> String {
        if let cdhash = app.cdhash { return "cdhash:" + cdhash }
        return "id:" + (app.signingID ?? "") + "/" + (app.teamID ?? "")
    }

    /// Takes a free slot, or waits for one until `startBy`. `queued` is true when the hook waited;
    /// `onQueued` is told how many hooks wait once this one does.
    private func admit(app: String, eventID: String, startBy: Date,
                       onQueued: @escaping @Sendable (Int) -> Void) async -> (Admission, queued: Bool) {
        var queued = false
        let admission: Admission = await withCheckedContinuation { continuation in
            lock.lock()
            if running < options.maximumConcurrent {
                running += 1
                lock.unlock()
                continuation.resume(returning: .admitted)
                return
            }
            guard startBy.timeIntervalSinceNow > 0 else {
                lock.unlock()
                continuation.resume(returning: .dropped(.deadlineNear))
                return
            }
            guard waitingTotal < options.maximumWaiting else {
                lock.unlock()
                continuation.resume(returning: .dropped(.queueFull))
                return
            }
            nextTicket += 1
            let ticket = nextTicket
            if waiting[app] == nil { turns.append(app) }
            waiting[app, default: []].append(Waiter(ticket: ticket, eventID: eventID, startBy: startBy,
                                                    continuation: continuation))
            waitingTotal += 1
            let waitingNow = waitingTotal
            queued = true
            lock.unlock()
            onQueued(waitingNow)
            // A timer, not a sleeping thread, gives the hook up once too little time is left.
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, startBy.timeIntervalSinceNow)) { [weak self] in
                self?.giveUp(ticket, app: app)
            }
        }
        return (admission, queued)
    }

    /// The waiting hook's start-by time came: drop it, if it still waits.
    private func giveUp(_ ticket: UInt64, app: String) {
        lock.lock()
        let list = waiting[app] ?? []
        guard let index = list.firstIndex(where: { $0.ticket == ticket }) else {
            lock.unlock()
            return
        }
        let waiter = list[index]
        setWaiters(list.filter { $0.ticket != ticket }, of: app)
        lock.unlock()
        waiter.continuation.resume(returning: .dropped(.deadlineNear))
    }

    /// Hands the slot to the next waiting hook, taking turns between apps, or frees it. A hook
    /// whose start-by time has passed is dropped on the way, before its timer fires.
    private func releaseSlot() {
        lock.lock()
        var late: [Waiter] = []
        var next: Waiter?
        while next == nil, !turns.isEmpty {
            let app = turns.removeFirst()
            var list = waiting[app] ?? []
            guard !list.isEmpty else { waiting[app] = nil; continue }
            let waiter = list.removeFirst()
            waitingTotal -= 1
            if list.isEmpty {
                waiting[app] = nil
            } else {
                waiting[app] = list
                turns.append(app)
            }
            if waiter.startBy.timeIntervalSinceNow > 0 { next = waiter } else { late.append(waiter) }
        }
        if next == nil { running -= 1 }
        lock.unlock()
        late.forEach { $0.continuation.resume(returning: .dropped(.deadlineNear)) }
        next?.continuation.resume(returning: .admitted)
    }

    /// Replaces an app's waiting hooks with `list`, keeping the counts and the turns in step.
    /// Call with the lock held.
    private func setWaiters(_ list: [Waiter], of app: String) {
        waitingTotal -= (waiting[app]?.count ?? 0) - list.count
        if list.isEmpty {
            waiting[app] = nil
            turns.removeAll { $0 == app }
        } else {
            waiting[app] = list
        }
    }

    /// mkdtemp creates the directory with mode 0700.
    private func makeEventDirectory() throws -> URL {
        var template = Array((options.workDirectory.path + "/hook-XXXXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else {
            throw FileSafetyError(options.workDirectory.path, "cannot create an event directory: \(errnoText(errno))")
        }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private struct SpawnedHook {
        let process: Process
        let pid: pid_t
        let stdin: Int32
        let stdout: Int32
        let stderr: Int32
    }

    /// Starts `executable` with `arguments` (argv[1...]) in `directory`, with exactly `environment`.
    /// With a `requirement`, the kernel starts the code only when it meets it, and otherwise kills
    /// it before its first instruction (Process.run does not throw then). Process passes the
    /// arguments and the environment decomposed, as file names are (NFD): an `ñ` in the notes
    /// reaches the agent as `n` and a combining tilde. Up to 1.0.2 they went as written.
    private func spawn(_ executable: String, _ arguments: [String], environment: [String: String], directory: String,
                       requirement: LaunchCodeRequirement?) throws -> SpawnedHook {
        var pipes: [[Int32]] = []
        for _ in 0..<3 {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else {
                let code = errno
                pipes.joined().forEach { close($0) }
                throw FileSafetyError("pipe", errnoText(code))
            }
            pipes.append(ends)
        }
        let (input, output, errors) = (pipes[0], pipes[1], pipes[2])
        // Not into another hook started meanwhile; Process puts the child's ends on 0, 1 and 2.
        for fd in pipes.joined() { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardInput = FileHandle(fileDescriptor: input[0], closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: output[1], closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errors[1], closeOnDealloc: false)
        process.launchRequirement = requirement
        do {
            try process.run()
        } catch {
            pipes.joined().forEach { close($0) }
            throw FileSafetyError(executable, "cannot start the hook: \((error as NSError).localizedDescription)")
        }
        close(input[0])
        close(output[1])
        close(errors[1])
        return SpawnedHook(process: process, pid: process.processIdentifier, stdin: input[1], stdout: output[0], stderr: errors[0])
    }

    /// Writes the event to the hook's stdin without ever blocking or raising SIGPIPE. A hook that
    /// exits or stops reading early loses the rest of stdin.
    private func feed(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        close(fd)
    }

    /// True once the process has exited: a zombie (WNOWAIT leaves it one), or reaped by Process.
    private func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 { return info.si_pid == pid }
        return errno != EINTR
    }

    /// Waits until Process has reaped the hook, so that its status is known.
    private func waitForTermination(_ child: SpawnedHook) {
        while child.process.isRunning { usleep(2_000) }
    }

    /// Whether the hook dies of SIGKILL within 50 ms of its start, as code the kernel refused does.
    private func killedAtOnce(_ child: SpawnedHook) -> Bool {
        let giveUp = uptime() + 0.05
        while !hasExited(child.pid) {
            guard uptime() < giveUp else { return false }
            usleep(2_000)
        }
        waitForTermination(child)
        return child.process.terminationReason == .uncaughtSignal && child.process.terminationStatus == SIGKILL
    }

    /// Whether the hook exits within a second with an exit status of its own, not killed by a
    /// signal: one the kernel would not start dies of SIGKILL at once.
    private func exitedOnItsOwn(_ child: SpawnedHook) -> Bool {
        let giveUp = uptime() + 1
        while !hasExited(child.pid) {
            guard uptime() < giveUp else { return false }
            usleep(5_000)
        }
        waitForTermination(child)
        return child.process.terminationReason == .exit
    }
}

/// Collects up to `limit` bytes from a pipe on its own thread and drains the rest, so a chatty
/// hook never blocks on a full pipe. Reading stops at end of file, or shortly after `stop` when a
/// process outside the hook's group still holds the pipe open.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let limit: Int
    private var data = Data()
    private var truncated = false
    private var stopAt: TimeInterval?

    init(limit: Int) { self.limit = limit }

    func start(reading fd: Int32) {
        Thread { self.read(fd) }.start()
    }

    func stop(after delay: TimeInterval) {
        lock.lock()
        stopAt = uptime() + delay
        lock.unlock()
    }

    func finish() -> (String, Bool) {
        let (bytes, cut) = finishData()
        return (String(decoding: bytes, as: UTF8.self), cut)
    }

    func finishData() -> (Data, Bool) {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }

    private func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopAt.map { uptime() >= $0 } ?? false
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !shouldStop() {
            let ready = poll(&poller, 1, 50)
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue } else { break } }
            lock.lock()
            let room = max(0, limit - data.count)
            data.append(contentsOf: buffer[0..<min(room, count)])
            if count > room { truncated = true }
            lock.unlock()
        }
        close(fd)
        done.signal()
    }
}

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw FileSafetyError(path, "write failed: \(errnoText(written < 0 ? errno : EIO))")
            }
        }
    }
}
