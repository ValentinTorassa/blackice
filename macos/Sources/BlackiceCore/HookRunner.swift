import Darwin
import Foundation

// Runs the [[hook]] commands for one event.
//
// The command line comes from blackice.toml, which the user wrote and the strict parser
// accepted, so it runs as `/bin/sh -c RUN`. Nothing from the event is ever put into that
// command line. The event reaches the hook in exactly two ways:
//   - as JSON on stdin;
//   - as the same bytes in a 0600 file inside a private 0700 directory, named in
//     BLACKICE_EVENT_FILE (BLACKICE_EVENT_ID holds the event ID). The hook also runs in
//     that directory, and the directory is deleted once the hook is done.
// The token is only in those two places: never in the environment, never in the log. A hook
// that writes it to stderr (an agent printing the command it ran) gets it replaced with
// "[token]" before stderr leaves the runner.
//
// Each hook gets its own process group. At the deadline the group gets SIGTERM and, after a
// grace period, SIGKILL. When the hook's shell exits, whatever it left behind in its group
// is killed too. A process that leaves the group on purpose (setsid, setpgid) escapes this.
//
// At most `maximumConcurrent` hooks run at once. A hook that finds no free slot does not
// run and does not wait: it is reported as dropped, and with no answer the connection is
// denied when its timeout passes.

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
        /// posix_spawn or the event file failed.
        case failedToStart(String)
    }

    public enum DropReason: String, Equatable, Sendable {
        case concurrencyLimit = "concurrency_limit"
        case deadlinePassed = "deadline_passed"
        case invalidEventID = "invalid_event_id"
    }

    /// Line of the hook's [[hook]] header in blackice.toml; identifies the hook.
    public let hookLine: Int
    public let outcome: Outcome
    /// The first `stderrLimit` bytes the hook wrote to stderr, decoded as UTF-8 with replacement.
    public let stderr: String
    public let stderrTruncated: Bool
    public let duration: TimeInterval

    public init(hookLine: Int, outcome: Outcome, stderr: String, stderrTruncated: Bool, duration: TimeInterval) {
        self.hookLine = hookLine
        self.outcome = outcome
        self.stderr = stderr
        self.stderrTruncated = stderrTruncated
        self.duration = duration
    }
}

public enum HookProgress: Sendable {
    case started(hookLine: Int, pid: Int32)
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
        /// Time between SIGTERM and SIGKILL.
        public var gracePeriod: TimeInterval
        public var stderrLimit: Int

        public init(workDirectory: URL, environment: [String: String], maximumConcurrent: Int = 4,
                    gracePeriod: TimeInterval = 2, stderrLimit: Int = 4096) {
            self.workDirectory = workDirectory
            self.environment = environment
            self.maximumConcurrent = maximumConcurrent
            self.gracePeriod = gracePeriod
            self.stderrLimit = stderrLimit
        }
    }

    public static let shell = "/bin/sh"
    /// launchd's PATH for agents. A hook that needs more sets PATH in its `run` line.
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let language = "en_US.UTF-8"

    public let options: Options
    private let lock = NSLock()
    private var running = 0

    public init(options: Options) throws {
        precondition(options.maximumConcurrent >= 1, "maximumConcurrent must be at least 1")
        try PrivateDirectory.ensure(options.workDirectory)
        self.options = options
    }

    /// The hook environment, built by the daemon rather than inherited from whoever started it:
    /// HOME, USER and LOGNAME from the user database, TMPDIR from confstr, a fixed PATH and LANG.
    /// The runner adds BLACKICE_EVENT_FILE and BLACKICE_EVENT_ID.
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

    /// Runs `hooks` for `event` side by side and returns one result per hook, in file order.
    /// Each hook is killed at `event.deadline` or after `timeoutSeconds`, whichever comes first.
    public func run(_ hooks: [Hook], for event: HookEvent, timeoutSeconds: Int,
                    progress: @escaping @Sendable (HookProgress) -> Void = { _ in }) async -> [HookResult] {
        await withTaskGroup(of: HookResult.self) { group in
            for hook in hooks {
                group.addTask {
                    // waitpid and the pipe reads block, so each hook gets its own thread
                    // instead of a thread from the concurrency pool.
                    await withCheckedContinuation { continuation in
                        Thread {
                            let result = self.runBlocking(hook, event: event, timeoutSeconds: timeoutSeconds, progress: progress)
                            progress(.finished(result))
                            continuation.resume(returning: result)
                        }.start()
                    }
                }
            }
            var results: [HookResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.hookLine < $1.hookLine }
        }
    }

    // MARK: - One hook

    private func runBlocking(_ hook: Hook, event: HookEvent, timeoutSeconds: Int,
                             progress: @Sendable (HookProgress) -> Void) -> HookResult {
        let started = uptime()
        func finish(_ outcome: HookResult.Outcome, stderr: String = "", truncated: Bool = false) -> HookResult {
            HookResult(hookLine: hook.line, outcome: outcome, stderr: stderr, stderrTruncated: truncated,
                       duration: uptime() - started)
        }

        guard Self.validEventID(event.id) else { return finish(.dropped(.invalidEventID)) }
        let budget = min(event.deadline.timeIntervalSinceNow, TimeInterval(timeoutSeconds))
        guard budget > 0 else { return finish(.dropped(.deadlinePassed)) }
        guard acquireSlot() else { return finish(.dropped(.concurrencyLimit)) }
        defer { releaseSlot() }

        let json: Data
        let directory: URL
        do {
            json = try event.jsonData()
            directory = try makeEventDirectory()
        } catch {
            return finish(.failedToStart("\(error)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventFile = directory.appendingPathComponent("event.json")
        do {
            try writePrivateFile(eventFile, json)
        } catch {
            return finish(.failedToStart("\(error)"))
        }

        var environment = options.environment.filter { key, value in
            !key.hasPrefix("BLACKICE_") && !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }
        environment["BLACKICE_EVENT_FILE"] = eventFile.path
        environment["BLACKICE_EVENT_ID"] = event.id

        let child: SpawnedHook
        do {
            child = try spawn(hook.run, environment: environment, directory: directory)
        } catch {
            return finish(.failedToStart("\(error)"))
        }
        progress(.started(hookLine: hook.line, pid: child.pid))

        let collector = OutputCollector(limit: options.stderrLimit)
        collector.start(reading: child.stderr)
        feed(json, to: child.stdin)

        let killAt = started + budget
        var lastSignal: Int32?
        var termSentAt: TimeInterval = 0
        while !hasExited(child.pid) {
            let now = uptime()
            if lastSignal == nil, now >= killAt {
                _ = kill(-child.pid, SIGTERM)
                lastSignal = SIGTERM
                termSentAt = now
            } else if lastSignal == SIGTERM, now >= termSentAt + options.gracePeriod {
                _ = kill(-child.pid, SIGKILL)
                lastSignal = SIGKILL
            }
            usleep(10_000)
        }
        // The shell is a zombie now, so its PID, which is also the group ID, cannot be reused yet.
        // Anything it left running in its group goes with it.
        _ = kill(-child.pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}

        collector.stop(after: 0.2)
        let (stderr, truncated) = collector.finish()

        let low = status & 0x7F
        let outcome: HookResult.Outcome
        if let lastSignal {
            outcome = .timedOut(signal: low != 0 && low != 0x7F ? low : lastSignal)
        } else if low == 0 {
            outcome = .exited(status: (status >> 8) & 0xFF)
        } else {
            outcome = .signaled(signal: low)
        }
        return finish(outcome, stderr: Self.redactToken(event.token, in: stderr), truncated: truncated)
    }

    /// Replaces the token in what a hook wrote. Agents echo the commands they run, sometimes cut
    /// short ("--token 'q8Zr0d3X..."), so every run of 8 or more base64url characters that is part
    /// of the token, or that holds it, becomes "[token]". Shorter pieces say little about the token.
    static func redactToken(_ token: String, in text: String) -> String {
        guard !token.isEmpty, !text.isEmpty else { return text }
        var result = ""
        var run = ""
        func flush() {
            let hides = run.count >= 8 && (token.contains(run) || run.contains(token))
            result += hides ? "[token]" : run
            run = ""
        }
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber || character == "-" || character == "_" {
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// Event IDs end up in an environment variable and the log; only plain characters are accepted.
    static func validEventID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func acquireSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running < options.maximumConcurrent else { return false }
        running += 1
        return true
    }

    private func releaseSlot() {
        lock.lock()
        running -= 1
        lock.unlock()
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

    private func writePrivateFile(_ url: URL, _ data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSafetyError(url.path, "cannot create the event file: \(errnoText(errno))") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw FileSafetyError(url.path, "cannot set mode 0600: \(errnoText(errno))") }
        try writeAll(fd, data, path: url.path)
    }

    private struct SpawnedHook {
        let pid: pid_t
        let stdin: Int32
        let stderr: Int32
    }

    private func spawn(_ command: String, environment: [String: String], directory: URL) throws -> SpawnedHook {
        var input: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw FileSafetyError("pipe", errnoText(errno)) }
        guard pipe(&errors) == 0 else {
            close(input[0]); close(input[1])
            throw FileSafetyError("pipe", errnoText(errno))
        }
        for fd in input + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; only descriptors 0-2 from the file actions are inherited; every signal
        // back to its default disposition and none blocked, whatever the daemon itself ignores.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = cStrings([Self.shell, "-c", command])
        let envp = cStrings(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, Self.shell, &actions, &attributes, argv, envp)
        close(input[0])
        close(errors[1])
        guard status == 0 else {
            close(input[1])
            close(errors[0])
            throw FileSafetyError(Self.shell, "cannot start the hook: \(errnoText(status))")
        }
        return SpawnedHook(pid: pid, stdin: input[1], stderr: errors[0])
    }

    /// Writes the event to the hook's stdin without ever blocking or raising SIGPIPE. A hook that
    /// exits or stops reading early loses the rest of stdin; it still has the event file.
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

    /// True once the process has exited. WNOWAIT leaves it a zombie, to be reaped by waitpid.
    private func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 { return info.si_pid == pid }
        return errno != EINTR
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
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), truncated)
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

private func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
    strings.map { strdup($0) } + [nil]
}

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
