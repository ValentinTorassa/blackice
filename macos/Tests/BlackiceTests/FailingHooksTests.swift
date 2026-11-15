import Darwin
import Foundation
import Testing
@testable import BlackiceCore

/// One `hook_no_answer` and the record before it, as the daemon writes them, for a hook that
/// exited with status 1 having written `stderr`.
private func failed(_ log: EventLog, _ id: String, at date: Date, stderr: String = "") throws {
    try log.append(.eventReceived(testEvent(id: id)), at: date)
    try log.append(.hookStarted(eventID: id, hookLine: 12, pid: 42), at: date)
    try log.append(.hookFinished(eventID: id, HookResult(hookLine: 12, outcome: .exited(status: 1), stderr: stderr,
                                                         stderrTruncated: false, duration: 2)), at: date)
    try log.append(.hookNoAnswer(eventID: id, hookLine: 12, .exitStatus(1)), at: date)
}

private func answered(_ log: EventLog, _ id: String, at date: Date) throws {
    try log.append(.eventReceived(testEvent(id: id)), at: date)
    try log.append(.hookStarted(eventID: id, hookLine: 12, pid: 43), at: date)
    try log.append(.hookFinished(eventID: id, HookResult(hookLine: 12, outcome: .exited(status: 0), stderr: "",
                                                         stderrTruncated: false, duration: 2)), at: date)
    try log.append(.hookAnswered(eventID: id, hookLine: 12, .deny), at: date)
}

private func lines(_ records: [String]) -> Data { Data((records.joined(separator: "\n") + "\n").utf8) }

struct FailingHooksTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let apiError = "fx ask: API request failed · HTTP 502 · insufficient_funds"

    /// A log as 1.0.7's daemon writes it, with no `hooks_failing` record: the run since the last
    /// answer, the time of its first failure and the last line its hook wrote to stderr.
    @Test func aRunWithNoAnswerIsReadFromTheHookRecords() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        try failed(log, "ev-00000001", at: start, stderr: "an old failure\n")
        try answered(log, "ev-00000002", at: start.addingTimeInterval(10))
        // Two in a row are not yet worth a word.
        try failed(log, "ev-00000003", at: start.addingTimeInterval(20), stderr: "Retrying…\n" + apiError + "\n")
        try failed(log, "ev-00000004", at: start.addingTimeInterval(30), stderr: apiError + "\n")
        #expect(FailingHooks.read(url: url) == nil)
        try failed(log, "ev-00000005", at: start.addingTimeInterval(40), stderr: "Retrying…\n" + apiError + "\n\n")
        #expect(FailingHooks.read(url: url) == FailingHooks(count: 3, since: start.addingTimeInterval(20),
                                                            last: start.addingTimeInterval(40), reason: apiError))

        // A deadline, a file in the agent's home, the daemon stopping: neither a failure nor an answer.
        try log.append(.hookNoAnswer(eventID: "ev-00000006", hookLine: 12, .deadline), at: start.addingTimeInterval(50))
        try log.append(.hookNoAnswer(eventID: "ev-00000007", hookLine: 12, .unsafeHome("/h/.claude/CLAUDE.md")),
                       at: start.addingTimeInterval(60))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"event":"ev-00000008","hook_line":12,"reason":"daemon_stopping","type":"hook_no_answer"}"# + "\n").utf8))
        try handle.close()
        // With no stderr, why it gave no answer.
        try log.append(.hookNoAnswer(eventID: "ev-00000009", hookLine: 12, .signaled(9)), at: start.addingTimeInterval(70))
        #expect(FailingHooks.read(url: url) == FailingHooks(count: 4, since: start.addingTimeInterval(20),
                                                            last: start.addingTimeInterval(70), reason: "it was ended by signal 9"))
        // The daemon takes up a run of any length.
        #expect(FailingHooks.read(url: url, minimum: 1)?.count == 4)

        // An answer ends it.
        try answered(log, "ev-0000000a", at: start.addingTimeInterval(80))
        #expect(FailingHooks.read(url: url) == nil)
        try failed(log, "ev-0000000b", at: start.addingTimeInterval(90), stderr: apiError)
        #expect(FailingHooks.read(url: url, minimum: 1) == FailingHooks(count: 1, since: start.addingTimeInterval(90),
                                                                         last: start.addingTimeInterval(90), reason: apiError))
        #expect(FailingHooks.read(url: directory.appendingPathComponent("none.jsonl")) == nil)
    }

    /// Only the end of the log is read: a run that began before it is "at least" that many, from
    /// the first failure it shows. The whole file, read from its start, shows where a run began.
    @Test func aRunThatBeganBeforeTheTailIsAtLeastThatLong() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        var count = 0
        func size() -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0 }
        while size() < FailingHooks.tailBytes + 4096 {
            count += 1
            try failed(log, String(format: "ev-%08x", count), at: start.addingTimeInterval(Double(count)), stderr: apiError)
        }
        let found = try #require(FailingHooks.read(url: url))
        #expect(found.atLeast && found.count < count && found.count >= count - 20)
        #expect(found.since == start.addingTimeInterval(Double(count - found.count + 1)) && found.reason == apiError)

        let whole = try #require(FailingHooks.parse(try Data(contentsOf: url), partialFirstLine: false))
        #expect(whole == FailingHooks(count: count, since: start.addingTimeInterval(1), last: start.addingTimeInterval(Double(count)),
                                      reason: apiError))
    }

    /// The daemon of 1.0.8 counts the run itself, from its start, and says when it ends; hooks with
    /// no answer after its record add to its count. A record of another shape is skipped.
    @Test func theDaemonsCountIsTaken() {
        let failing = #"{"type":"hooks_failing","count":297,"reason":"exit_status","stderr_line":"\#(apiError)","since":"2027-01-15T14:02:00.250Z","ts":"2027-01-15T16:40:00.000Z"}"#
        let noAnswer = #"{"type":"hook_no_answer","event":"ev-00000001","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T16:41:00.000Z"}"#
        let since = FailingHooks.date("2027-01-15T14:02:00.250Z")
        // Read from inside the file: the record still gives the whole count, and when it began.
        #expect(FailingHooks.parse(lines(["piece of a record\"}", failing]), partialFirstLine: true)
            == FailingHooks(count: 297, since: since, last: FailingHooks.date("2027-01-15T16:40:00.000Z"), reason: apiError))
        #expect(FailingHooks.parse(lines(["x", failing, noAnswer, noAnswer]), partialFirstLine: true)
            == FailingHooks(count: 299, since: since, last: FailingHooks.date("2027-01-15T16:41:00.000Z"),
                            reason: "it exited with status 1"))
        // With no stderr line, its reason in words.
        let bare = #"{"type":"hooks_failing","count":5,"reason":"no_line"}"#
        #expect(FailingHooks.parse(lines([bare]), partialFirstLine: false) == FailingHooks(count: 5, reason: "it printed no answer"))
        // Recovered, or answered since: nothing to say.
        #expect(FailingHooks.parse(lines([failing, #"{"type":"hooks_recovered","after":297}"#]), partialFirstLine: true) == nil)
        #expect(FailingHooks.parse(lines([failing, #"{"type":"hook_answer","event":"ev-00000002","hook_line":12,"answer":"deny"}"#]),
                                   partialFirstLine: true) == nil)
        #expect(FailingHooks.parse(lines([#"{"type":"hooks_failing","count":"many"}"#, "not json", "[1]"]),
                                   partialFirstLine: false) == nil)
    }

    /// A daemon that started again in the middle of a run counted it from 1, and the log shows
    /// only its end: neither makes the run shorter or later. A record's count with the hooks with
    /// no answer after it, or the hooks the log shows, whichever is more, since the earliest time
    /// either knows.
    @Test func aDaemonThatStartedAgainDoesNotShortenTheRun() {
        func noAnswer(_ index: Int, at time: String) -> String {
            #"{"type":"hook_no_answer","event":"ev-0000000\#(index)","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T\#(time).000Z"}"#
        }
        func failing(_ count: Int, since: String, at time: String) -> String {
            #"{"type":"hooks_failing","count":\#(count),"reason":"exit_status","stderr_line":"\#(apiError)","since":"2027-01-15T\#(since).000Z","ts":"2027-01-15T\#(time).000Z"}"#
        }
        // 297 counted since 05:02, one more, then the daemon starts again and counts 3 from 07:50.
        let restarted = [failing(297, since: "05:02:00", at: "07:30:00"), noAnswer(1, at: "07:31:00"), noAnswer(2, at: "07:50:00"),
                         noAnswer(3, at: "07:51:00"), noAnswer(4, at: "07:52:00"), failing(3, since: "07:50:00", at: "07:52:00")]
        let expected = FailingHooks(count: 301, since: FailingHooks.date("2027-01-15T05:02:00.000Z"),
                                    last: FailingHooks.date("2027-01-15T07:52:00.000Z"), reason: apiError)
        #expect(FailingHooks.parse(lines(["piece of a record\"}"] + restarted), partialFirstLine: true) == expected)
        #expect(FailingHooks.parse(lines(restarted), partialFirstLine: false) == expected)
        // The log shows more than the daemon that started again counted: the log's count, from its first.
        let shown = [noAnswer(1, at: "07:00:00"), noAnswer(2, at: "07:10:00"), noAnswer(3, at: "07:50:00"), noAnswer(4, at: "07:51:00"),
                     noAnswer(5, at: "07:52:00"), failing(3, since: "07:50:00", at: "07:52:00")]
        #expect(FailingHooks.parse(lines(shown), partialFirstLine: false)
            == FailingHooks(count: 5, since: FailingHooks.date("2027-01-15T07:00:00.000Z"),
                            last: FailingHooks.date("2027-01-15T07:52:00.000Z"), reason: apiError))
        // From inside the file, with no record that counted more than it shows: at least that many.
        #expect(FailingHooks.parse(lines(["x"] + shown), partialFirstLine: true)?.atLeast == true)
        // An answer ends the run, the records before it included.
        #expect(FailingHooks.parse(lines(restarted + [#"{"type":"hooks_recovered","after":3}"#, noAnswer(5, at: "08:00:00")]),
                                   partialFirstLine: false, minimum: 1)?.count == 1)
    }

    /// The end of the log can hold the daemon's record and every failure it counted, but not the
    /// answer before them: the record counted the run from its start, so the count is the whole
    /// run's, not "at least" that many. A record that counted fewer than the log shows up to it
    /// is from a daemon that lost count, and the run may have begun before the stretch.
    @Test func aRecordThatCountedEveryFailureShownGivesTheWholeRun() {
        func noAnswer(_ index: Int, at time: String) -> String {
            #"{"type":"hook_no_answer","event":"ev-0000000\#(index)","hook_line":12,"reason":"exit_status","status":1,"ts":"2027-01-15T\#(time).000Z"}"#
        }
        let failing = #"{"type":"hooks_failing","count":3,"reason":"exit_status","stderr_line":"\#(apiError)","since":"2027-01-15T07:00:00.000Z","ts":"2027-01-15T07:02:00.000Z"}"#
        let run = [noAnswer(1, at: "07:00:00"), noAnswer(2, at: "07:01:00"), noAnswer(3, at: "07:02:00"), failing]
        #expect(FailingHooks.parse(lines(["piece of a record\"}"] + run), partialFirstLine: true)
            == FailingHooks(count: 3, since: FailingHooks.date("2027-01-15T07:00:00.000Z"),
                            last: FailingHooks.date("2027-01-15T07:02:00.000Z"), reason: apiError))
        // Hooks with no answer after it add to the whole count.
        let longer = FailingHooks.parse(lines(["x"] + run + [noAnswer(4, at: "07:03:00")]), partialFirstLine: true)
        #expect(longer?.count == 4 && longer?.atLeast == false)
        // Without the record, the same stretch is at least that many.
        #expect(FailingHooks.parse(lines(["x"] + run.dropLast()), partialFirstLine: true)?.atLeast == true)
        // A record that counted fewer leaves it at least that many.
        let short = #"{"type":"hooks_failing","count":2,"reason":"exit_status","ts":"2027-01-15T07:02:00.000Z"}"#
        let lost = FailingHooks.parse(lines(["x"] + run.dropLast() + [short]), partialFirstLine: true)
        #expect(lost?.count == 3 && lost?.atLeast == true)
    }

    /// `status` and the menu say so for an hour after the latest failure, not for ever: the
    /// answerer may have been switched or mended, with nothing asked since.
    @Test func aRunIsShownForAnHourAfterTheLatestFailure() {
        let run = FailingHooks(count: 297, since: start, last: start.addingTimeInterval(7200))
        #expect(run.isRecent(at: start.addingTimeInterval(7200)))
        #expect(run.isRecent(at: start.addingTimeInterval(7200 + FailingHooks.shownFor - 1)))
        #expect(!run.isRecent(at: start.addingTimeInterval(7200 + FailingHooks.shownFor)))
        #expect(!FailingHooks(count: 297, since: start).isRecent(at: start))
    }

    /// What a hook writes to stderr is shown once made safe, and its escape sequences go first:
    /// colors, a window title, a link.
    @Test func escapeSequencesAreTakenOut() {
        #expect(FailingHooks.withoutEscapes("\u{1B}[1;31mError:\u{1B}[0m quota") == "Error: quota")
        #expect(FailingHooks.withoutEscapes("\u{1B}]0;title\u{07}a\u{1B}]8;;https://x.example\u{1B}\\link\u{1B}]8;;\u{1B}\\b")
            == "alinkb")
        #expect(FailingHooks.withoutEscapes("\u{9B}2Kx\u{1B}(By\u{1B}=z") == "xyz")
        #expect(FailingHooks.withoutEscapes("plain · text") == "plain · text")
        #expect(FailingHooks.withoutEscapes("cut\u{1B}[") == "cut")
        #expect(FailingHooks.lastLine("first\n\u{1B}[31m  last one  \u{1B}[0m\r\n  \n") == "last one")
        #expect(FailingHooks.lastLine(" \n\t\n") == nil)
        #expect(FailingHooks.lastLine(String(repeating: "a", count: 2000))?.count == FailingHooks.reasonLimit)
    }
}
