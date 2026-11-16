import Darwin
import Foundation
import Testing
@testable import BlackiceCore

private func finished(_ id: String, _ outcome: HookResult.Outcome, line: Int = 12) -> LogRecord {
    .hookFinished(eventID: id, HookResult(hookLine: line, outcome: outcome, stderr: "", stderrTruncated: false, duration: 2))
}

struct EndedEventsTests {
    /// What a daemon that starts reads from the log of the one before it: the events whose hooks ran
    /// to their end, and not those it has to run again.
    @Test func onlyEventsWhoseHooksRanToTheirEndAreRead() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        func received(_ id: String) throws { try log.append(.eventReceived(testEvent(id: id))) }
        func started(_ id: String, line: Int = 12) throws { try log.append(.hookStarted(eventID: id, hookLine: line, pid: 42)) }

        // Exited with no answer, and killed at its deadline: both had their say.
        try received("ev-exited"); try started("ev-exited"); try log.append(finished("ev-exited", .exited(status: 0)))
        try log.append(.hookNoAnswer(eventID: "ev-exited", hookLine: 12, .exitStatus(1)))
        try received("ev-deadline"); try started("ev-deadline")
        try log.append(finished("ev-deadline", .timedOut(signal: SIGTERM)))
        // Refused for its signature: it would be refused again.
        try received("ev-refused"); try log.append(finished("ev-refused", .refused(found: "apple/com.apple.sh")))

        // Stopped by the daemon's own end, while running or while waiting for a slot.
        try received("ev-stopped"); try started("ev-stopped")
        try log.append(finished("ev-stopped", .timedOut(signal: SIGTERM, reason: .daemonStopping)))
        try received("ev-waiting"); try log.append(.hookQueued(eventID: "ev-waiting", hookLine: 12, waiting: 1))
        try log.append(finished("ev-waiting", .dropped(.daemonStopping)))
        // The daemon was killed: a hook started with no end, and an event with no hook record.
        try received("ev-killed"); try started("ev-killed")
        try received("ev-alone")
        // Never started, for want of a slot: it has not run.
        try received("ev-full"); try log.append(finished("ev-full", .dropped(.queueFull)))
        // Two hooks, one ended and one still running when the daemon was killed.
        try received("ev-two"); try started("ev-two", line: 12); try started("ev-two", line: 20)
        try log.append(finished("ev-two", .exited(status: 0), line: 12))
        // No hook ran for want of the configuration.
        try received("ev-skipped"); try log.append(.hooksSkipped(eventID: "ev-skipped", reason: "configuration_unavailable"))

        #expect(EndedEvents(url: url).ids == ["ev-exited", "ev-deadline", "ev-refused"])
        #expect(EndedEvents(url: directory.appendingPathComponent("none.jsonl")).ids.isEmpty)
    }

    /// The daemon that took an event last is the one that counts: a second one that ran the hooks
    /// of an event the first was stopped at ends it, and one stopped at an event the first ended
    /// leaves it to run again. One it skipped stays as it was.
    @Test func theLastDaemonThatTookAnEventCounts() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        for id in ["ev-a", "ev-b", "ev-c"] {
            try log.append(.eventReceived(testEvent(id: id)))
            try log.append(.hookStarted(eventID: id, hookLine: 12, pid: 42))
        }
        try log.append(finished("ev-a", .timedOut(signal: SIGTERM, reason: .daemonStopping)))
        try log.append(finished("ev-b", .exited(status: 0)))
        try log.append(finished("ev-c", .exited(status: 0)))
        #expect(EndedEvents(url: url).ids == ["ev-b", "ev-c"])

        // The next daemon: it runs ev-a's hook to its end, is stopped at ev-b's, and skips ev-c.
        try log.append(.eventReceived(testEvent(id: "ev-a")))
        try log.append(.hookStarted(eventID: "ev-a", hookLine: 12, pid: 43))
        try log.append(finished("ev-a", .exited(status: 0)))
        try log.append(.eventReceived(testEvent(id: "ev-b")))
        try log.append(.hookStarted(eventID: "ev-b", hookLine: 12, pid: 44))
        try log.append(finished("ev-b", .timedOut(signal: SIGTERM, reason: .daemonStopping)))
        try log.append(.hooksSkipped(eventID: "ev-c", reason: "already_ran"))
        #expect(EndedEvents(url: url).ids == ["ev-a", "ev-c"])
    }

    /// An event is told by its ID and its deadline, which the log keeps to the second: another
    /// event that one day gets the same ID still runs its hooks.
    @Test func anotherEventWithTheSameIDIsNotOneOfThem() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let event = testEvent(id: "ev-1", deadlineIn: 20.75)
        try log.append(.eventReceived(event))
        try log.append(finished("ev-1", .exited(status: 0)))
        let ended = EndedEvents(url: url)
        #expect(ended.contains(event))
        #expect(!ended.contains(testEvent(id: "ev-1", deadlineIn: 60)))
        #expect(!ended.contains(testEvent(id: "ev-2", deadlineIn: 20.75)))
    }

    /// A resent event is one whose token no answer presented. So when its hook answered, the answer
    /// was lost on its way, and the hook runs again; an answer refused for what it said would be
    /// refused again, and its hook does not.
    @Test func anEventWhoseAnswerDidNotArriveRunsAgain() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        func answered(_ id: String, refused reason: String?) throws {
            try log.append(.eventReceived(testEvent(id: id)))
            try log.append(.hookStarted(eventID: id, hookLine: 12, pid: 42))
            try log.append(finished(id, .exited(status: 0)))
            try log.append(.hookAnswered(eventID: id, hookLine: 12, .deny))
            if let reason { try log.append(.answerRefused(eventID: id, hookLine: 12, reason: reason)) }
        }
        // The daemon was killed as it sent the answer, the extension could not be reached, and its
        // reply did not come in time.
        try answered("ev-sending", refused: nil)
        try answered("ev-unreachable", refused: "unreachable")
        try answered("ev-timeout", refused: "reply_timeout")
        // The event names no app an answer can be for: no answer was sent, and none would be.
        try answered("ev-invalid", refused: "invalid_event")
        #expect(EndedEvents(url: url).ids == ["ev-invalid"])
    }

    /// A stretch that starts inside the file: its first line is a piece of a record, and an event
    /// whose `event_received` is before the stretch is not assumed to have ended.
    @Test func anEventReceivedBeforeTheStretchIsNotAssumedEnded() throws {
        let record = { (fields: String) in "{\(fields)}" }
        let text = [
            #"12,"type":"hook_exited"}"#,
            record(#""event":"ev-before","hook_line":12,"status":0,"type":"hook_exited""#),
            record(#""deadline":"2026-11-16T18:05:39Z","event":"ev-in","type":"event_received""#),
            record(#""event":"ev-in","hook_line":12,"pid":7,"type":"hook_started""#),
            "not a record",
            record(#""event":"ev-in","hook_line":12,"status":0,"type":"hook_exited""#),
            // No deadline to tell it by: it is left out.
            record(#""event":"ev-undated","type":"event_received""#),
            record(#""event":"ev-undated","hook_line":12,"status":0,"type":"hook_exited""#),
        ].joined(separator: "\n") + "\n"
        let ended = EndedEvents(Data(text.utf8), partialFirstLine: true)
        #expect(ended.ids == ["ev-in"])
        #expect(ended.deadlines["ev-in"] == Date(timeIntervalSince1970: 1_794_852_339))
        #expect(EndedEvents(Data(), partialFirstLine: false).ids.isEmpty)
    }
}
