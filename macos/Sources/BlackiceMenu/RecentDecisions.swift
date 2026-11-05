import Darwin
import Foundation
import BlackiceCore

/// One verdict from the daemon's event log, with the app and host of its event.
public struct RecentDecision: Equatable, Sendable {
    /// Who gave an answer.
    public enum Answerer: Equatable, Sendable {
        /// A hook, whose answer the daemon sent and the extension took.
        case hook
        /// Not a hook: a person, with Touch ID.
        case hand
    }

    public let verdict: Verdict
    /// Already cleaned for the menu (MenuText).
    public let app: String
    public let host: String
    public let date: Date?
    /// For approved and denied; nil when the log does not say (a log written before hooks
    /// answered on their output, or a hook still running).
    public let by: Answerer?

    public init(verdict: Verdict, app: String, host: String, date: Date?, by: Answerer? = nil) {
        self.verdict = verdict
        self.app = app
        self.host = host
        self.date = date
        self.by = by
    }
}

/// What the menu takes from the end of the event log.
public struct EventLogSummary: Equatable, Sendable {
    /// Newest first.
    public var decisions: [RecentDecision]
    /// The last `hook_refused`: the daemon killed a hook program whose signature did not match,
    /// so that hook decides nothing.
    public var hookRefused: Date?

    public init(decisions: [RecentDecision] = [], hookRefused: Date? = nil) {
        self.decisions = decisions
        self.hookRefused = hookRefused
    }
}

/// Reads ~/Library/Logs/blackice/events.jsonl. Only the end of the file is read, and it is read
/// again only when its size or modification time changes.
public final class RecentDecisions {
    /// How much of the end of the log is read: some hundred records, a few dozen events.
    public static let tailBytes = 65_536

    private let url: URL
    private var stamp: (size: off_t, modified: timespec)?
    private var cached = EventLogSummary()

    public init(url: URL) { self.url = url }

    /// The last `limit` verdicts, newest first, and the last hook refused; empty when there is no
    /// log.
    public func latest(limit: Int) -> EventLogSummary {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { stamp = nil; cached = EventLogSummary(); return cached }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return EventLogSummary() }
        if stamp == nil || stamp?.size != info.st_size || stamp?.modified.tv_sec != info.st_mtimespec.tv_sec
            || stamp?.modified.tv_nsec != info.st_mtimespec.tv_nsec {
            let start = max(0, info.st_size - off_t(Self.tailBytes))
            guard lseek(descriptor, start, SEEK_SET) == start else { return EventLogSummary() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = (try? handle.read(upToCount: Self.tailBytes)) ?? Data()
            cached = Self.parse(data, partialFirstLine: start > 0, limit: 32)
            stamp = (info.st_size, info.st_mtimespec)
        }
        return EventLogSummary(decisions: Array(cached.decisions.prefix(limit)), hookRefused: cached.hookRefused)
    }

    /// How long after a hook's answer the events it closed get their verdicts. One answer closes
    /// every event that waits for the same app and host, each with a verdict of its own.
    static let answerWindow: TimeInterval = 5

    /// The verdicts in `data`, newest first, at most `limit`. A verdict counts only when its event
    /// (`event_received`) is in the same stretch, since that is where the app and host are. An
    /// approval or a denial was a hook's when a `hook_answer` of the same kind, not followed by
    /// `answer_refused`, was logged for its event, or shortly before for another event of the same
    /// app and host. Otherwise it was a person's when no hook of its event was still waiting or
    /// running; when one was (or a log from before hooks answered on their output says no more),
    /// who answered is left unknown. Lines that are not records of the log's shape are skipped;
    /// when the stretch starts inside the file, its first line is a piece of a record and is
    /// skipped too.
    public static func parse(_ data: Data, partialFirstLine: Bool, limit: Int) -> EventLogSummary {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        var events: [String: (app: String, host: String, key: String?)] = [:]
        var verdicts: [(id: String, verdict: Verdict, date: Date?)] = []
        // The hook lines of each event that are queued or running.
        var running: [String: Set<Int>] = [:]
        var answers: [(event: String, hookLine: Int, kind: String, date: Date?)] = []
        var refused: Set<String> = []
        var summary = EventLogSummary()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, let id = object["event"] as? String, validEventID(id) else { continue }
            let hookLine = object["hook_line"] as? Int ?? 0
            let date = (object["ts"] as? String).flatMap(Self.date)
            switch type {
            case "event_received":
                let identity: AppIdentity?
                if let signingID = object["app_signing_id"] as? String, validSigningID(signingID) {
                    let team = (object["app_team_id"] as? String).flatMap { validTeamID($0) ? $0 : nil }
                    identity = .signed(SigningIdentity(signingID: signingID, teamID: team))
                } else if let cdhash = object["app_cdhash"] as? String, validCDHash(cdhash) {
                    identity = .cdhash(cdhash)
                } else {
                    identity = nil
                }
                let raw = object["host"] as? String
                let host = raw.map(MenuText.host) ?? (object["ip"] as? String).map(MenuText.host)
                // What the extension's approvals are keyed by: the app and the host.
                let key = identity.flatMap { identity in raw.map { identity.label + " " + $0.lowercased() } }
                events[id] = (MenuText.appName(path: object["app_path"] as? String, identity: identity), host ?? "unknown host", key)
            case "hook_queued", "hook_started":
                running[id, default: []].insert(hookLine)
            case "hook_answer":
                running[id]?.remove(hookLine)
                if let kind = object["answer"] as? String { answers.append((id, hookLine, kind, date)) }
            case "answer_refused":
                refused.insert("\(id) \(hookLine)")
            case "hook_refused", "hook_no_answer", "hook_dropped", "hook_failed":
                running[id]?.remove(hookLine)
                if type == "hook_refused" { summary.hookRefused = date ?? summary.hookRefused }
            case "verdict":
                guard let raw = object["verdict"] as? String, let verdict = Verdict(rawValue: raw) else { continue }
                verdicts.append((id, verdict, date))
            default:
                continue
            }
        }
        let taken = answers.filter { !refused.contains("\($0.event) \($0.hookLine)") }
        for entry in verdicts.reversed() {
            guard let event = events[entry.id] else { continue }
            var by: RecentDecision.Answerer?
            let kind = entry.verdict == .approved ? "approve" : entry.verdict == .denied ? "deny" : nil
            if let kind {
                let closedByHook = taken.contains { answer in
                    guard answer.kind == kind else { return false }
                    if answer.event == entry.id { return true }
                    guard let key = event.key, events[answer.event]?.key == key, let answered = answer.date,
                          let decided = entry.date else { return false }
                    return (0...answerWindow).contains(decided.timeIntervalSince(answered))
                }
                if closedByHook {
                    by = .hook
                } else if running[entry.id]?.isEmpty ?? true {
                    by = .hand
                }
            }
            summary.decisions.append(RecentDecision(verdict: entry.verdict, app: event.app, host: event.host,
                                                    date: entry.date, by: by))
            if summary.decisions.count == limit { break }
        }
        return summary
    }

    /// The log's timestamps: ISO 8601 with fractional seconds.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
