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
    /// The last line the latest of them wrote to stderr, else why it gave no answer, with escape
    /// sequences taken out. Otherwise as the hook wrote it: it is shown only once made safe for
    /// the terminal or the menu. nil when the log does not say.
    public let reason: String?

    public init(count: Int, atLeast: Bool = false, since: Date? = nil, reason: String? = nil) {
        self.count = count
        self.atLeast = atLeast
        self.since = since
        self.reason = reason
    }

    /// The run of hooks with no answer at the end of the log at `url`, read from its last
    /// `tailBytes`; nil when there are fewer than `threshold` in a row, or there is no log.
    public static func read(url: URL) -> FailingHooks? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let start = max(0, info.st_size - off_t(tailBytes))
        var data = Data(count: Int(info.st_size - start))
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, start) }
        guard read >= 0 else { return nil }
        return parse(data.prefix(read), partialFirstLine: start > 0)
    }

    /// The run in `data`, a stretch of the log; nil when there are fewer than `threshold`.
    ///
    /// A run is the `hook_no_answer` records since the last `hook_answer`, leaving out those of a
    /// neutral reason. The daemon of 1.0.8 also writes `hooks_failing`, with the run's count, the
    /// time it began and the last line the hook wrote to stderr, and `hooks_recovered` once a hook
    /// answers again: its count and time are taken as they are, and the hooks with no answer after
    /// it are added. A log from before has none. When the stretch starts inside the file and shows
    /// neither an answer nor such a record before the run, the run began earlier: `atLeast`.
    /// Lines that are not records of the log's shape are skipped, and so is the first line when
    /// the stretch starts inside the file, since it is a piece of a record.
    public static func parse(_ data: Data, partialFirstLine: Bool) -> FailingHooks? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        var run = 0
        var first: Date?
        var reason: String?
        var seenStart = !partialFirstLine
        var reported: (count: Int, since: Date?, reason: String?)?
        // The last line each hook that ran wrote to stderr, by event and hook line, until its
        // `hook_no_answer` comes.
        var errors: [String: String] = [:]
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "hook_exited", "hook_signaled":
                if let key = hookKey(object), let text = object["stderr"] as? String, let last = lastLine(text) {
                    errors[key] = last
                }
            case "hook_answer", "hooks_recovered":
                run = 0
                first = nil
                reason = nil
                reported = nil
                seenStart = true
                errors.removeAll()
            case "hooks_failing":
                guard let count = object["count"] as? Int, count > 0 else { continue }
                let line = (object["stderr_line"] as? String).flatMap(lastLine)
                reported = (count, (object["since"] as? String).flatMap(date),
                            line ?? (object["reason"] as? String).flatMap(lastLine).map { describe($0) })
                run = 0
                first = nil
                reason = nil
            case "hook_no_answer":
                guard let why = object["reason"] as? String, !neutralReasons.contains(why) else { continue }
                run += 1
                if first == nil { first = (object["ts"] as? String).flatMap(date) }
                let key = hookKey(object)
                reason = key.flatMap { errors.removeValue(forKey: $0) } ?? describe(why, status: object["status"] as? Int,
                                                                                     signal: object["signal"] as? Int)
            default:
                continue
            }
        }
        let found: FailingHooks
        if let reported {
            found = FailingHooks(count: reported.count + run, since: reported.since ?? first, reason: reason ?? reported.reason)
        } else {
            found = FailingHooks(count: run, atLeast: !seenStart, since: first, reason: reason)
        }
        return found.count >= threshold ? found : nil
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
