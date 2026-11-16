import Foundation

/// The events whose hooks the daemon before this one ran to their end, read from the end of the
/// event log when a daemon starts.
///
/// The extension sends a daemon that registers every event still waiting (since 1.1.0). Among them
/// are events whose hooks already ended with no answer that counted: on 16 November 2026 a daemon
/// that started again got four such events, and their hook ran a second time. An agent would be
/// called twice for one connection, and a hook that notifies would notify twice. Those run no hook
/// again (`hooks_skipped`, `already_ran`).
///
/// An event's hooks run again when the daemon's own end stopped one (`daemon_stopping`), when one
/// started or queued has no end in the log (the daemon was killed), or when none ran at all. So do
/// those of an event whose `event_received` is before the stretch read: nothing is assumed of it.
///
/// They also run again when a hook answered and the answer did not reach the extension
/// (`answer_refused` with `unreachable` or `reply_timeout`, or no record after `hook_answer`): the
/// extension sends again only events whose token no answer presented (`PendingTable.unanswered`),
/// so that answer was lost, and the token it needed is in no log. Skipping the event would leave
/// its connection to be dropped at the deadline after an agent approved it.
///
/// An event is told by its ID and its deadline together (`contains`). The daemon keeps what it
/// read for as long as it runs, and an ID alone, eight hexadecimal digits, could one day be that
/// of a new event, whose hooks would then not run.
public struct EndedEvents: Sendable, Equatable {
    /// Each event's deadline as its `event_received` has it, to the second.
    let deadlines: [String: Date]

    var ids: Set<String> { Set(deadlines.keys) }

    /// Whether `event` is one of them: it has the ID and, to the second, the deadline.
    public func contains(_ event: HookEvent) -> Bool {
        guard let deadline = deadlines[event.id] else { return false }
        return abs(deadline.timeIntervalSince(event.deadline)) < 1
    }

    /// The types a hook that started, or could not, ends with. A dropped hook (`hook_dropped`) never
    /// started, and does not make its event one that ran.
    static let ends: Set<String> = ["hook_exited", "hook_signaled", "hook_killed", "hook_failed", "hook_refused"]

    /// The reasons of an `answer_refused` that say the answer did not get to the extension.
    static let lost: Set<String> = ["unreachable", "reply_timeout"]

    /// The events in the last `FailingHooks.tailBytes` of the log at `url`; none when there is no log.
    public init(url: URL) {
        let tail = FailingHooks.tail(of: url)
        self.init(tail?.data ?? Data(), partialFirstLine: tail?.partial ?? false)
    }

    /// The events in `data`, a stretch of the log. Lines that are not records of the log's shape are
    /// skipped, and so is the first line when the stretch starts inside the file. An event whose
    /// `event_received` has no deadline that can be read is left out.
    init(_ data: Data, partialFirstLine: Bool) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        var events: [String: State] = [:]
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String, let id = record["event"] as? String else { continue }
            if type == "event_received" {
                // A daemon took it, for the first time or again: what the one before did no longer counts.
                events[id] = State(deadline: (record["deadline"] as? String).flatMap(FailingHooks.date))
                continue
            }
            guard var state = events[id] else { continue }
            let line = record["hook_line"] as? Int
            switch type {
            case "hook_queued", "hook_started":
                if let line { state.open.insert(line) }
            case "hook_dropped":
                if let line { state.open.remove(line) }
            case _ where Self.ends.contains(type):
                if let line { state.open.remove(line) }
                state.ran = true
            case "hook_answer":
                // Not known to have arrived: a record follows only when it was refused.
                if let line { state.undelivered.insert(line) }
            case "answer_refused":
                // Refused for what it said: the same answer would be refused again.
                if let line, !Self.lost.contains(record["reason"] as? String ?? "") { state.undelivered.remove(line) }
            default:
                continue
            }
            if record["reason"] as? String == "daemon_stopping" { state.stopped = true }
            events[id] = state
        }
        deadlines = events.compactMapValues { $0.ended ? $0.deadline : nil }
    }

    private struct State {
        var deadline: Date?
        /// The hook lines queued or started with no end yet.
        var open = Set<Int>()
        var ran = false
        /// The daemon's end stopped or dropped one of its hooks.
        var stopped = false
        /// The hook lines that answered, with nothing to say the extension got the answer.
        var undelivered = Set<Int>()

        var ended: Bool { ran && !stopped && open.isEmpty && undelivered.isEmpty }
    }
}
