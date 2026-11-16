import Darwin
import Foundation

// An agent that runs and gives no answer, event after event: its provider refuses it (no credit
// left, a key revoked, an outage), or the program fails before it decides. Every event it should
// answer then waits until its deadline and is dropped, and until 1.0.8 neither `blackice status`
// nor the menu said so: only the daemon's event log did. This reads that log's end, as the menu
// reads its recent decisions, so that both can say it.

/// Hooks that ran and gave no answer, one after another, read from the end of the daemon's event
/// log (events.jsonl).
public struct FailingHooks: Equatable, Sendable {
    /// From this many in a row on, `status` and the menu say so: one or two can be a moment's
    /// trouble on the network.
    public static let threshold = 3
    /// How much of the end of the log is read, as the menu reads it for its recent decisions.
    public static let tailBytes = 65_536
    /// How long after the latest of them `status` and the menu still say so, as long as the menu
    /// shows a hook it refused: an answerer switched or mended, and nothing asked since, is not
    /// worth a warning hours later.
    public static let shownFor: TimeInterval = 3600
    /// The longest reason kept, in characters. A program's error line is seldom longer, and a
    /// longer one is cut where it is shown anyway.
    static let reasonLimit = 512

    /// `hook_no_answer` reasons that say nothing about whether the answerer works: `deadline`, a
    /// hook still deciding when its event's time ran out; `agent_home`, a file in the agent's home
    /// that voided its answer, which the menu says apart; `daemon_stopping`, a hook the daemon
    /// stopped as it exited. They neither count nor end a run.
    static let neutralReasons: Set<String> = ["deadline", "agent_home", "daemon_stopping"]

    /// How many hooks in a row gave no answer.
    public let count: Int
    /// Whether the run began before the stretch of log read, so that there were at least `count`,
    /// and `since` is when the first of those read failed.
    public let atLeast: Bool
    /// When the first of them gave no answer; nil when the log does not say.
    public let since: Date?
    /// When the latest of them gave no answer; nil when the log does not say.
    public let last: Date?
    /// The last line the latest of them wrote to stderr, else why it gave no answer, with escape
    /// sequences taken out. Otherwise as the hook wrote it: it is shown only once made safe for
    /// the terminal or the menu. nil when the log does not say.
    public let reason: String?

    public init(count: Int, atLeast: Bool = false, since: Date? = nil, last: Date? = nil, reason: String? = nil) {
        self.count = count
        self.atLeast = atLeast
        self.since = since
        self.last = last
        self.reason = reason
    }

    /// Whether the latest of them failed less than `shownFor` before `now`, so that `status` and
    /// the menu still say so; not when the log does not say when.
    public func isRecent(at now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < Self.shownFor
    }

    /// The run of hooks with no answer at the end of the log at `url`, read from its last
    /// `tailBytes`; nil when there are fewer than `minimum` in a row, or there is no log.
    public static func read(url: URL, minimum: Int = threshold) -> FailingHooks? {
        guard let tail = tail(of: url) else { return nil }
        return parse(tail.data, partialFirstLine: tail.partial, minimum: minimum)
    }

    /// The last `tailBytes` of the log at `url`, and whether they start inside the file; nil when
    /// there is no log to read.
    static func tail(of url: URL) -> (data: Data, partial: Bool)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let start = max(0, info.st_size - off_t(tailBytes))
        var data = Data(count: Int(info.st_size - start))
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, start) }
        guard read >= 0 else { return nil }
        return (data.prefix(read), start > 0)
    }

    /// The run in `data`, a stretch of the log (`Tally`); nil when there are fewer than `minimum`.
    /// Lines that are not records of the log's shape are skipped, and so is the first line when
    /// the stretch starts inside the file, since it is a piece of a record.
    public static func parse(_ data: Data, partialFirstLine: Bool, minimum: Int = threshold) -> FailingHooks? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        var tally = Tally(fromStart: !partialFirstLine)
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            tally.take(object)
        }
        return tally.run(minimum: minimum)
    }

    /// The run at the end of a stretch of the log, from its records taken in order. The menu hands
    /// it the records it decodes for its recent decisions, so that the stretch is decoded once.
    ///
    /// A run is the `hook_no_answer` records since the last `hook_answer` or `hooks_recovered`,
    /// leaving out those of a neutral reason. The daemon of 1.0.8 also writes `hooks_failing`, with
    /// its own count of the run, the time the run began and the last line the hook wrote to
    /// stderr. Neither replaces the other, since either can fall short: the stretch is only the
    /// end of the log, and the daemon keeps its count in memory, so one that started again (the
    /// extension restarted, an upgrade, a logout) knows only what the end of the log showed it
    /// then. The run is the longest either says, a record's count with the hooks with no answer
    /// after it, and began at the earliest time either knows. When the stretch starts inside the
    /// file and shows neither an answer nor a record that counted at least the hooks with no
    /// answer the stretch shows up to it, the run began earlier: `atLeast`. A record that counted
    /// as many is the daemon's count from the start of the run, even when it counted no more than
    /// the stretch shows: the stretch then holds the whole run, but not the answer before it.
    public struct Tally {
        /// Hooks with no answer in the run, as the stretch shows them.
        private var count = 0
        /// The most a `hooks_failing` record of the run counted beyond the hooks with no answer
        /// the stretch shows up to it: those before the stretch.
        private var beyond = 0
        /// Whether a `hooks_failing` record of the run counted at least the hooks with no answer
        /// the stretch shows up to it, so that the run's count is whole. One that counted fewer
        /// is from a daemon that started again and lost count, and says nothing of where the run
        /// began.
        private var whole = false
        private var since: Date?
        private var last: Date?
        private var reason: String?
        private var fromStart: Bool
        /// The last line each hook that ran wrote to stderr, by event and hook line, until its
        /// `hook_no_answer` comes.
        private var errors: [String: String] = [:]

        /// `fromStart`: the stretch starts at the start of the log, so a run it shows began there.
        public init(fromStart: Bool) { self.fromStart = fromStart }

        /// Takes the next record of the stretch, as JSONSerialization decodes it; other records,
        /// and anything not of the log's shape, change nothing.
        public mutating func take(_ object: [String: Any]) {
            guard let type = object["type"] as? String else { return }
            switch type {
            case "hook_exited", "hook_signaled":
                if let key = hookKey(object), let text = object["stderr"] as? String, let line = lastLine(text) {
                    errors[key] = line
                }
            case "hook_answer", "hooks_recovered":
                self = Tally(fromStart: true)
            case "hooks_failing":
                guard let counted = object["count"] as? Int, counted > 0 else { return }
                beyond = max(beyond, counted - count)
                if counted >= count { whole = true }
                since = earliest(since, (object["since"] as? String).flatMap(FailingHooks.date))
                last = Self.time(object) ?? last
                // It follows the `hook_no_answer` it counted: its stderr line, else the reason
                // taken from that record, which has the status, else its own reason in words.
                reason = (object["stderr_line"] as? String).flatMap(lastLine) ?? reason
                    ?? (object["reason"] as? String).flatMap(lastLine).map { describe($0) }
            case "hook_no_answer":
                guard let why = object["reason"] as? String, !neutralReasons.contains(why) else { return }
                let time = Self.time(object)
                count += 1
                since = earliest(since, time)
                last = time ?? last
                reason = hookKey(object).flatMap { errors.removeValue(forKey: $0) }
                    ?? describe(why, status: object["status"] as? Int, signal: object["signal"] as? Int)
            default:
                return
            }
        }

        /// The run at the end of the records taken; nil when there are fewer than `minimum`.
        public func run(minimum: Int = FailingHooks.threshold) -> FailingHooks? {
            let total = count + beyond
            guard total > 0, total >= minimum else { return nil }
            return FailingHooks(count: total, atLeast: !fromStart && !whole, since: since, last: last, reason: reason)
        }

        private func earliest(_ known: Date?, _ other: Date?) -> Date? {
            guard let known, let other else { return known ?? other }
            return min(known, other)
        }

        /// When the record was written; read only for the records of a run.
        private static func time(_ object: [String: Any]) -> Date? {
            (object["ts"] as? String).flatMap(FailingHooks.date)
        }
    }

    /// `text` without the escape sequences a program sends a terminal: colors, cursor moves,
    /// titles and links (CSI, OSC and the other ESC and C1 sequences). Other characters stay;
    /// whoever shows the text makes those safe.
    public static func withoutEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\u{1B}" || (0x80...0x9F).contains($0.value) }) else { return text }
        var kept = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar.value {
            case 0x1B:
                guard let next = scalars.popFirst() else { break }
                switch next {
                case "[": skipControlSequence(&scalars)
                case "]", "P", "X", "^", "_": skipString(&scalars)
                default:
                    // ESC, intermediates, one final character.
                    var final = next
                    while (0x20...0x2F).contains(final.value), let after = scalars.popFirst() { final = after }
                }
            case 0x9B: skipControlSequence(&scalars)
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F: skipString(&scalars)
            case 0x80...0x9F: continue
            default: kept.append(scalar)
            }
        }
        return String(kept)
    }

    /// Parameters and intermediates, up to and with the final character (0x40 to 0x7E).
    private static func skipControlSequence(_ scalars: inout ArraySlice<Unicode.Scalar>) {
        while let scalar = scalars.popFirst() {
            if (0x40...0x7E).contains(scalar.value) { return }
        }
    }

    /// Up to and with the string terminator: BEL, ESC \ or ST.
    private static func skipString(_ scalars: inout ArraySlice<Unicode.Scalar>) {
        while let scalar = scalars.popFirst() {
            if scalar.value == 0x07 || scalar.value == 0x9C { return }
            if scalar.value == 0x1B {
                if scalars.first == "\\" { scalars.removeFirst() }
                return
            }
        }
    }

    /// The last line of `text` with something on it, escape sequences out, cut at
    /// `reasonLimit`; nil when there is none.
    static func lastLine(_ text: String) -> String? {
        let lines = withoutEscapes(text).split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        guard let last = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        return String(last.trimmingCharacters(in: .whitespaces).prefix(reasonLimit))
    }

    /// Why a hook gave no answer, in words, from its `hook_no_answer` reason.
    static func describe(_ reason: String, status: Int? = nil, signal: Int? = nil) -> String {
        switch reason {
        case "exit_status": return status.map { "it exited with status \($0)" } ?? "it exited with an error"
        case "signaled": return signal.map { "it was ended by signal \($0)" } ?? "it was ended by a signal"
        case "no_line": return "it printed no answer"
        case "unrecognized_line": return "its last line was not an answer"
        case "output_too_long": return "its output was too long"
        default: return reason
        }
    }

    private static func hookKey(_ object: [String: Any]) -> String? {
        guard let event = object["event"] as? String, let hookLine = object["hook_line"] as? Int else { return nil }
        return "\(event) \(hookLine)"
    }

    /// The log's time stamps: ISO 8601 with fractional seconds, or without.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
