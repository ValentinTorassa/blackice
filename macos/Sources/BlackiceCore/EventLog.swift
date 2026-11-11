import Darwin
import Foundation

// The event log: append-only JSON Lines.
//
// Each record is one JSON object encoded by JSONEncoder, which escapes newlines and other
// control characters inside strings, so a host name or a hook's stderr cannot start a new
// line or forge a record. The file is opened with O_APPEND | O_NOFOLLOW, kept at mode 0600,
// and its directory must be a private 0700 directory. A failed write throws: callers decide
// how to make it visible, and nothing is dropped silently.
//
// The event token is never written to the log, and neither is a hook's stdout: an answer is
// logged as what it means, and a line that is not one only as a short printable prefix. There is
// no rotation yet.

public enum Verdict: String, Codable, Sendable {
    case approved
    case denied
    case timedOut = "timed_out"
    /// The extension dropped the connection without an answer: the configuration changed or the
    /// filter stopped.
    case cancelled
}

public enum LogRecord: Sendable {
    /// The daemon took a configuration from the extension: the hooks of later events come from it.
    case configurationLoaded(DaemonConfiguration)
    case eventReceived(HookEvent)
    case noHooks(eventID: String)
    /// No hook ran for the event: "configuration_unavailable" when the extension could not be asked
    /// for its configuration, "configuration_changed" when it holds a newer one than the event's.
    case hooksSkipped(eventID: String, reason: String)
    /// No hook slot was free, so the hook waits; `waiting` hooks wait now, this one included.
    case hookQueued(eventID: String, hookLine: Int, waiting: Int)
    /// `waited` is how long it waited for a slot; 0 when one was free.
    case hookStarted(eventID: String, hookLine: Int, pid: Int32, waited: TimeInterval = 0)
    case hookFinished(eventID: String, HookResult)
    /// A hook that ran answered on its stdout; the daemon sends the answer to the extension.
    case hookAnswered(eventID: String, hookLine: Int, HookAnswer)
    /// A hook that ran gave no answer. An unrecognized line is logged only as a short prefix.
    case hookNoAnswer(eventID: String, hookLine: Int, HookResult.NoAnswer)
    /// The extension did not take a hook's answer: `reason` is its short code (token_spent when
    /// another hook answered first, token_expired, ...) or "unreachable".
    case answerRefused(eventID: String, hookLine: Int, reason: String)
    /// Written when the extension reports how a paused connection ended.
    case verdict(eventID: String, Verdict)
}

public final class EventLog: @unchecked Sendable {
    /// Hook stderr is cut to this many characters in the log.
    public static let maximumStderrCharacters = 2048

    public let url: URL
    private let lock = NSLock()
    private var fd: Int32

    /// Opens `url` for appending, creating it with mode 0600. Its directory is created with mode
    /// 0700 if missing and refused if anyone else can enter it. The file must be a regular file
    /// owned by the current user with a single link; a symlink is refused.
    public init(url: URL) throws {
        try PrivateDirectory.ensure(url.deletingLastPathComponent())
        let path = url.path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            throw FileSafetyError(path, code == ELOOP ? "is a symlink" : "cannot open the log: \(errnoText(code))")
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw FileSafetyError(path, "cannot inspect the log: \(errnoText(code))")
        }
        let problem: String? =
            (info.st_mode & S_IFMT) != S_IFREG ? "is not a regular file"
            : info.st_uid != geteuid() ? "is owned by another user"
            : info.st_nlink != 1 ? "has more than one link"
            : nil
        if let problem {
            close(fd)
            throw FileSafetyError(path, problem)
        }
        if (info.st_mode & 0o777) != 0o600, fchmod(fd, 0o600) != 0 {
            let code = errno
            close(fd)
            throw FileSafetyError(path, "cannot set mode 0600: \(errnoText(code))")
        }
        self.url = url
        self.fd = fd
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Appends one record as one line. Throws when the line could not be written in full.
    public func append(_ record: LogRecord, at date: Date = Date()) throws {
        var line = try Self.encode(record, at: date)
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw FileSafetyError(url.path, "the log is closed") }
        try writeAll(fd, line, path: url.path)
    }

    /// For tests: makes every later append fail.
    func closeForTesting() {
        lock.lock()
        if fd >= 0 { close(fd) }
        fd = -1
        lock.unlock()
    }

    /// One record as one line of JSON, without the newline.
    static func encode(_ record: LogRecord, at date: Date) throws -> Data {
        var fields: [String: Field] = ["ts": .string(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))]
        switch record {
        case .configurationLoaded(let configuration):
            fields["type"] = .string("configuration_loaded")
            fields["generation"] = .int(Int(clamping: configuration.generation))
            fields["hooks"] = .int(configuration.hooks.count)
            fields["timeout_seconds"] = .int(configuration.timeoutSeconds)
        case .hooksSkipped(let eventID, let reason):
            fields["type"] = .string("hooks_skipped")
            fields["event"] = .string(eventID)
            fields["reason"] = .string(reason)
        case .eventReceived(let event):
            fields["type"] = .string("event_received")
            fields["event"] = .string(event.id)
            fields["app_signing_id"] = event.app.signingID.map(Field.string)
            fields["app_team_id"] = event.app.teamID.map(Field.string)
            fields["app_cdhash"] = event.app.cdhash.map(Field.string)
            fields["app_path"] = event.app.path.map(Field.string)
            // What the agent was shown, never trusted (ProcessArguments): the review of its answers needs it.
            fields["app_script"] = event.app.script.map(Field.string)
            fields["app_title"] = event.app.title.map(Field.string)
            fields["host"] = event.host.map(Field.string)
            fields["ip"] = .string(event.ip)
            fields["port"] = .int(Int(event.port))
            fields["deadline"] = .string(event.deadline.formatted(Date.ISO8601FormatStyle()))
        case .noHooks(let eventID):
            fields["type"] = .string("no_hooks")
            fields["event"] = .string(eventID)
        case .hookQueued(let eventID, let hookLine, let waiting):
            fields["type"] = .string("hook_queued")
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(hookLine)
            fields["waiting"] = .int(waiting)
        case .hookStarted(let eventID, let hookLine, let pid, let waited):
            fields["type"] = .string("hook_started")
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(hookLine)
            fields["pid"] = .int(Int(pid))
            if waited > 0 { fields["waited_ms"] = .int(milliseconds(waited)) }
        case .hookFinished(let eventID, let result):
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(result.hookLine)
            fields["duration_ms"] = .int(milliseconds(result.duration))
            if result.waited > 0 { fields["waited_ms"] = .int(milliseconds(result.waited)) }
            switch result.outcome {
            case .exited(let status):
                fields["type"] = .string("hook_exited")
                fields["status"] = .int(Int(status))
            case .signaled(let signal):
                fields["type"] = .string("hook_signaled")
                fields["signal"] = .int(Int(signal))
            case .timedOut(let signal):
                fields["type"] = .string("hook_killed")
                fields["reason"] = .string("deadline")
                fields["signal"] = .int(Int(signal))
            case .dropped(let reason):
                fields["type"] = .string("hook_dropped")
                fields["reason"] = .string(reason.rawValue)
            case .failedToStart(let message):
                fields["type"] = .string("hook_failed")
                fields["error"] = .string(message)
            case .refused(let found):
                fields["type"] = .string("hook_refused")
                fields["reason"] = .string("signature")
                fields["found"] = .string(found)
            case .unsafeHome(let path):
                fields["type"] = .string("hook_refused")
                fields["reason"] = .string("agent_home")
                fields["path"] = .string(path)
            }
            if !result.stderr.isEmpty {
                let cut = result.stderr.count > maximumStderrCharacters
                fields["stderr"] = .string(cut ? String(result.stderr.prefix(maximumStderrCharacters)) : result.stderr)
                if cut || result.stderrTruncated { fields["stderr_truncated"] = .bool(true) }
            }
        case .hookAnswered(let eventID, let hookLine, let answer):
            fields["type"] = .string("hook_answer")
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(hookLine)
            switch answer {
            case .approve(let seconds):
                fields["answer"] = .string("approve")
                fields["seconds"] = .int(seconds)
            case .deny:
                fields["answer"] = .string("deny")
            }
        case .hookNoAnswer(let eventID, let hookLine, let missing):
            fields["type"] = .string("hook_no_answer")
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(hookLine)
            fields["reason"] = .string(missing.reason)
            switch missing {
            case .exitStatus(let status): fields["status"] = .int(Int(status))
            case .signaled(let signal): fields["signal"] = .int(Int(signal))
            case .output(.unrecognized(let prefix)): fields["line_prefix"] = .string(prefix)
            case .unsafeHome(let path): fields["path"] = .string(path)
            case .deadline, .output: break
            }
        case .answerRefused(let eventID, let hookLine, let reason):
            fields["type"] = .string("answer_refused")
            fields["event"] = .string(eventID)
            fields["hook_line"] = .int(hookLine)
            fields["reason"] = .string(reason)
        case .verdict(let eventID, let verdict):
            fields["type"] = .string("verdict")
            fields["event"] = .string(eventID)
            fields["verdict"] = .string(verdict.rawValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fields)
        // JSONEncoder never emits a raw newline without .prettyPrinted; keep it that way.
        precondition(!data.contains(0x0A) && !data.contains(0x0D), "a log record must be one line")
        return data
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    enum Field: Encodable {
        case string(String)
        case int(Int)
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }
}
