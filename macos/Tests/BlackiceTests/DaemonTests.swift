import Darwin
import Foundation
import Testing
@testable import BlackiceCore

/// Stands in for the extension: hands the daemon a fixed list of messages, then ends. Each call to
/// `configuration()` returns the next entry of `fetches` (the last one again when they run out),
/// or fails when there is none.
private final class FakeIntake: EventIntake, @unchecked Sendable {
    let list: [IntakeMessage]
    private let lock = NSLock()
    private var fetches: [DaemonConfiguration]
    private var fetchCount = 0

    init(_ list: [IntakeMessage], fetches: [DaemonConfiguration] = []) {
        self.list = list
        self.fetches = fetches
    }

    var fetched: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchCount
    }

    func messages() -> AsyncStream<IntakeMessage> {
        AsyncStream { continuation in
            for message in list { continuation.yield(message) }
            continuation.finish()
        }
    }

    func configuration() async throws -> DaemonConfiguration {
        guard let next = nextFetch() else { throw MessageError("registration", "was refused") }
        return next
    }

    let answers = Recorder<AnswerRequest>()

    func answer(_ request: AnswerRequest) async throws -> AnswerReply {
        answers.append(request)
        return AnswerReply(status: .done, reason: request.kind == .approve ? "approved" : "denied", message: "ok")
    }

    private func nextFetch() -> DaemonConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        fetchCount += 1
        guard let next = fetches.first else { return nil }
        if fetches.count > 1 { fetches.removeFirst() }
        return next
    }
}

/// Stands in for an extension that goes away: hands the daemon `list`, then ends once `until`
/// holds (or after 10 s), and notes when.
private final class EndingIntake: EventIntake, @unchecked Sendable {
    let list: [IntakeMessage]
    let until: @Sendable () -> Bool
    let ended = Recorder<Date>()

    init(_ list: [IntakeMessage], until: @escaping @Sendable () -> Bool) {
        self.list = list
        self.until = until
    }

    func messages() -> AsyncStream<IntakeMessage> {
        AsyncStream { continuation in
            for message in list { continuation.yield(message) }
            Task {
                let giveUp = Date().addingTimeInterval(10)
                while !self.until(), Date() < giveUp { try? await Task.sleep(nanoseconds: 10_000_000) }
                self.ended.append(Date())
                continuation.finish()
            }
        }
    }

    func configuration() async throws -> DaemonConfiguration { throw MessageError("registration", "was refused") }

    func answer(_ request: AnswerRequest) async throws -> AnswerReply { throw MessageError("connection", "is gone") }
}

private func records(_ url: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

private func types(_ log: [[String: Any]], event: String) -> [String] {
    log.filter { $0["event"] as? String == event }.compactMap { $0["type"] as? String }
}

/// A configuration whose one hook writes the event to `<dir>/<tag>-<event id>.json`.
private func configuration(_ generation: UInt64, writingTo dir: URL, tag: String, timeout: Int = 5) throws -> DaemonConfiguration {
    try DaemonConfiguration(generation: generation, configText: """
    mode = "ask"
    timeout_seconds = \(timeout)

    [[hook]]
    on = "connection"
    run = "cat > \(quotedPath(dir))/\(tag)-$BLACKICE_EVENT_ID.json"
    """)
}

/// One configuration with these hooks, each a `run` line.
private func hooks(_ runs: String...) throws -> DaemonConfiguration {
    try DaemonConfiguration(generation: 1, configText: "mode = \"ask\"\ntimeout_seconds = 5\n" + runs.map {
        "[[hook]]\non = \"connection\"\nrun = '\($0)'\n"
    }.joined())
}

/// Records what the daemon sends, and answers with `reply`.
private final class Answers: @unchecked Sendable {
    let sent = Recorder<AnswerRequest>()
    var reply: (AnswerRequest) throws -> AnswerReply = {
        AnswerReply(status: .done, reason: $0.kind == .approve ? "approved" : "denied", message: "ok")
    }

    var send: AnswerSender {
        { request in
            self.sent.append(request)
            return try self.reply(request)
        }
    }
}

struct DaemonTests {
    /// An event the extension sends twice, on its own and again when the daemon registers, runs
    /// its hooks once; another event still runs them.
    @Test func anEventSentTwiceRunsItsHooksOnce() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let first = testEvent(id: "ev-8"), other = testEvent(host: "two.example", id: "ev-9")
        let intake = FakeIntake([.registered(try hooks("echo approve 10m")), .event(first, generation: 1),
                                 .event(first, generation: 1), .event(other, generation: 1)])
        await daemon.run(intake)

        #expect(intake.answers.items.map(\.host).sorted() == ["example.com", "two.example"])
        let log = try records(logURL)
        let repeated = types(log, event: "ev-8")
        #expect(repeated.filter { $0 == "hook_started" }.count == 1)
        #expect(repeated.filter { $0 == "hooks_skipped" }.count == 1)
        #expect(log.contains { $0["event"] as? String == "ev-8" && $0["reason"] as? String == "already_received" })
        #expect(types(log, event: "ev-9") == ["event_received", "hook_started", "hook_exited", "hook_answer"])
    }

    /// The extension sends the daemon that starts next the events still waiting. One whose hook
    /// the daemon before it ran to its end runs none again; one whose hook that daemon's own end
    /// stopped runs it again, and so does an event that is new.
    @Test func aDaemonThatStartsAgainRunsNoHookThatHadEnded() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let ended = testEvent(id: "ev-1"), stopped = testEvent(host: "two.example", id: "ev-2")
        // The first daemon: ev-1's hook exits with no answer, and ev-2's sleeps until the intake ends.
        let first = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir, grace: 0.3))
        let going = EndingIntake([.registered(try hooks(#"case "$BLACKICE_EVENT_ID" in ev-1) exit 0;; *) sleep 30;; esac"#)),
                                  .event(ended, generation: 1), .event(stopped, generation: 1)]) {
            let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
            return lines.contains { $0.contains(#""event":"ev-1""#) && $0.contains(#""type":"hook_no_answer""#) }
                && lines.contains { $0.contains(#""event":"ev-2""#) && $0.contains(#""type":"hook_started""#) }
        }
        await first.run(going, stopHooksWhenIntakeEnds: true)
        var log = try records(logURL)
        #expect(types(log, event: "ev-1") == ["event_received", "hook_started", "hook_exited", "hook_no_answer"])
        #expect(types(log, event: "ev-2") == ["event_received", "hook_started", "hook_killed"])
        #expect(log.last { $0["event"] as? String == "ev-2" }?["reason"] as? String == "daemon_stopping")

        // The next daemon, which reads that log as it starts, gets both again, and one more.
        let second = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let again = FakeIntake([.registered(try hooks("echo approve 10m")), .event(ended, generation: 1),
                                .event(stopped, generation: 1), .event(testEvent(host: "three.example", id: "ev-3"), generation: 1)])
        await second.run(again)
        #expect(again.answers.items.map(\.host).sorted() == ["three.example", "two.example"])
        log = try records(logURL)
        #expect(types(log, event: "ev-1") == ["event_received", "hook_started", "hook_exited", "hook_no_answer", "hooks_skipped"])
        #expect(log.last { $0["event"] as? String == "ev-1" }?["reason"] as? String == "already_ran")
        #expect(types(log, event: "ev-2").suffix(4) == ["event_received", "hook_started", "hook_exited", "hook_answer"])
        #expect(types(log, event: "ev-3") == ["event_received", "hook_started", "hook_exited", "hook_answer"])
    }

    @Test func runsTheHooksOfTheConfigurationFromTheRegistration() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("logs/events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let events = [testEvent(id: "ev-1"), testEvent(host: "two.example", id: "ev-2")]
        let intake = FakeIntake([.registered(try configuration(4, writingTo: dir, tag: "g4"))] +
                                events.map { .event($0, generation: 4) })
        await daemon.run(intake)

        for event in events {
            #expect(try Data(contentsOf: dir.appendingPathComponent("g4-\(event.id).json")) == event.input.jsonData())
        }
        #expect(intake.fetched == 0)
        // cat prints nothing, so nothing was answered.
        #expect(intake.answers.items.isEmpty)
        let log = try records(logURL)
        #expect(log.first?["type"] as? String == "configuration_loaded")
        #expect(log.first?["generation"] as? Int == 4 && log.first?["hooks"] as? Int == 1)
        #expect(log.first?["timeout_seconds"] as? Int == 5)
        for id in ["ev-1", "ev-2"] {
            #expect(types(log, event: id) == ["event_received", "hook_started", "hook_exited", "hook_no_answer"], "\(id)")
        }
        #expect(log.last?["reason"] as? String == "no_line")
        #expect(!(try String(contentsOf: logURL, encoding: .utf8)).contains(testToken))
    }

    /// The owner's notes from [agent] reach each hook as notes.md beside the event, 0600; with none
    /// there is no file.
    @Test func theOwnersNotesAreBesideTheEvent() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let daemon = Daemon(log: try EventLog(url: dir.appendingPathComponent("events.jsonl")), runner: try testRunner(dir))
        let copy = "{ stat -f %Lp notes.md && cat notes.md; } > \(quotedPath(dir))/$BLACKICE_EVENT_ID.notes 2>&1"
        let text = "mode = \"ask\"\ntimeout_seconds = 5\n[[hook]]\non = \"connection\"\nrun = \"\(copy)\"\n"
        await daemon.run(FakeIntake([
            .registered(try DaemonConfiguration(generation: 1, configText: text + "[agent]\nnotes = '''\nDeny analytics hosts.'''\n")),
            .event(testEvent(id: "ev-1"), generation: 1),
        ]))
        await daemon.run(FakeIntake([
            .registered(try DaemonConfiguration(generation: 2, configText: text)),
            .event(testEvent(id: "ev-2"), generation: 2),
        ]))
        #expect(try String(contentsOf: dir.appendingPathComponent("ev-1.notes"), encoding: .utf8) == "600\nDeny analytics hosts.\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("ev-2.notes"), encoding: .utf8).contains("No such file"))
    }

    /// The hook's last line is the answer. The daemon sends it for the event's app and host, with
    /// the event's token, through the intake: the hook never had the token.
    @Test func anAnswerGoesToTheExtensionWithTheEventsToken() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let event = testEvent(host: "api.example.com", id: "ev-3")
        // The hook names another app and host, and reads the event: neither changes what is answered.
        let intake = FakeIntake([.registered(try hooks(#"grep -c token "$BLACKICE_EVENT_FILE" >&2; echo "It is fine."; echo approve 10m"#)),
                                 .event(event, generation: 1)])
        await daemon.run(intake)

        let sent = try #require(intake.answers.items.first)
        #expect(intake.answers.items.count == 1)
        #expect(sent == AnswerRequest(kind: .approve, app: try #require(event.app.identity), host: "api.example.com",
                                      seconds: 600, token: testToken))
        #expect(sent.authorization == .token)
        let log = try records(logURL)
        #expect(types(log, event: "ev-3") == ["event_received", "hook_started", "hook_exited", "hook_answer"])
        let answer = try #require(log.last)
        #expect(answer["answer"] as? String == "approve" && answer["seconds"] as? Int == 600)
        // grep found no token in the event file, and nothing the hook printed is in the log.
        let exited = try #require(log.first { $0["type"] as? String == "hook_exited" })
        #expect(exited["stderr"] as? String == "0\n")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!text.contains(testToken) && !text.contains("It is fine"))
    }

    @Test func aDenialIsSentToo() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let daemon = Daemon(log: try EventLog(url: dir.appendingPathComponent("events.jsonl")), runner: try testRunner(dir))
        let answers = Answers()
        await daemon.handle(testEvent(id: "ev-4"), with: try hooks("printf \"deny\\n\\n\""), send: answers.send)
        #expect(answers.sent.items.map(\.kind) == [.deny] && answers.sent.items[0].seconds == nil)
        #expect(answers.sent.items[0].token == testToken && answers.sent.items[0].host == "example.com")
    }

    @Test(arguments: [
        ("echo approve 10m; exit 1", "exit_status"),
        ("echo Approve 10m", "unrecognized_line"),
        ("echo approve 2d", "unrecognized_line"),
        ("echo approve 10m; echo but maybe not", "unrecognized_line"),
        ("true", "no_line"),
        ("echo approve 10m; kill -SEGV $$", "signaled"),
    ])
    func anythingElseIsNoAnswer(_ run: String, _ reason: String) async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let answers = Answers()
        await daemon.handle(testEvent(id: "ev-5"), with: try hooks(run), send: answers.send)
        #expect(answers.sent.items.isEmpty, "\(run)")
        let last = try #require(try records(logURL).last)
        #expect(last["type"] as? String == "hook_no_answer" && last["reason"] as? String == reason, "\(run)")
    }

    @Test func aHookKilledAtTheDeadlineGaveNoAnswer() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir, grace: 0.2))
        let answers = Answers()
        // Room for a slow CI runner to start the hook before the deadline. On 10 November 2026 2.5 s
        // was not enough: the deadline had passed when the runner took the hook, which was dropped
        // and never started. Such a run shows nothing of a kill, so it is done once more with 4.5 s,
        // still under the 5 s timeout of `hooks`, which would kill the hook first.
        var id = ""
        for (event, room) in [("ev-6", 2.5), ("ev-6-again", 4.5)] {
            id = event
            await daemon.handle(testEvent(id: id, deadlineIn: room), with: try hooks("echo approve 1h; sleep 30"), send: answers.send)
            if types(try records(logURL), event: id).last != "hook_dropped" { break }
        }
        #expect(answers.sent.items.isEmpty)
        let log = try records(logURL)
        #expect(types(log, event: id).suffix(2) == ["hook_killed", "hook_no_answer"])
        #expect(log.last?["reason"] as? String == "deadline")
    }

    /// With two hooks the first answer counts; the extension refuses the second, and the log says so.
    @Test func theFirstOfTwoAnswersCounts() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let answers = Answers()
        let spent = Recorder<Bool>()
        answers.reply = { request in
            defer { spent.append(true) }
            return spent.items.isEmpty ? AnswerReply(status: .done, reason: "denied", message: "ok")
                : AnswerReply(status: .refused, reason: "token_spent", message: "this token was already used")
        }
        await daemon.handle(testEvent(id: "ev-7"), with: try hooks("echo deny", "sleep 0.5; echo approve 24h"), send: answers.send)
        #expect(answers.sent.items.map(\.kind) == [.deny, .approve])
        let log = try records(logURL)
        #expect(types(log, event: "ev-7").filter { $0.hasPrefix("hook_answer") || $0 == "answer_refused" }
                == ["hook_answer", "hook_answer", "answer_refused"])
        #expect(log.last?["reason"] as? String == "token_spent" && log.last?["hook_line"] as? Int == 6)

        // An extension that cannot be reached.
        answers.reply = { _ in throw MessageError("connection", "is gone") }
        await daemon.handle(testEvent(id: "ev-8"), with: try hooks("echo deny"), send: answers.send)
        #expect(try records(logURL).last?["type"] as? String == "answer_refused")
        #expect(try records(logURL).last?["reason"] as? String == "unreachable")
    }

    @Test func aRequestNamesTheEventsAppAndHost() throws {
        let adHoc = HookEvent(id: "ev-0a1b2c3d", token: testToken, app: .init(signingID: nil, teamID: nil, cdhash: testCDHash, path: nil),
                              host: "api.github.com", ip: "203.0.113.7", port: 443, deadline: Date())
        #expect(Daemon.request(.approve(seconds: 60), for: adHoc)
                == AnswerRequest(kind: .approve, app: .cdhash(testCDHash), host: "api.github.com", seconds: 60, token: testToken))
        #expect(Daemon.request(.deny, for: testEvent(host: nil)) == nil)
        let request = try #require(Daemon.request(.deny, for: testEvent()))
        #expect(throws: Never.self) { try request.validate(now: Date()) }
    }

    @Test func aNewGenerationIsFetchedFromTheExtension() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let intake = FakeIntake([.registered(try configuration(1, writingTo: dir, tag: "old")),
                                 .event(testEvent(id: "ev-5"), generation: 2)],
                                fetches: [try configuration(2, writingTo: dir, tag: "new")])
        await daemon.run(intake)

        #expect(intake.fetched == 1)
        #expect(fileExists(dir.appendingPathComponent("new-ev-5.json")))
        #expect(!fileExists(dir.appendingPathComponent("old-ev-5.json")))
        let log = try records(logURL)
        #expect(log.filter { $0["type"] as? String == "configuration_loaded" }.compactMap { $0["generation"] as? Int } == [1, 2])
        #expect(types(log, event: "ev-5") == ["event_received", "hook_started", "hook_exited", "hook_no_answer"])
    }

    @Test func anEventFromAConfigurationThatIsGoneRunsNoHook() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        // The daemon holds 1, the event says 2, and by the time it asks the extension holds 3.
        let intake = FakeIntake([.registered(try configuration(1, writingTo: dir, tag: "g1")),
                                 .event(testEvent(id: "ev-6"), generation: 2)],
                                fetches: [try configuration(3, writingTo: dir, tag: "g3")])
        await daemon.run(intake)

        #expect(intake.fetched == 1)
        let log = try records(logURL)
        #expect(types(log, event: "ev-6") == ["event_received", "hooks_skipped"])
        #expect(log.last?["reason"] as? String == "configuration_changed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func withoutAConfigurationNoHookRuns() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        // No registration reached the daemon and the extension cannot be asked.
        await daemon.run(FakeIntake([.event(testEvent(id: "ev-7"), generation: 1)]))
        let log = try records(logURL)
        #expect(types(log, event: "ev-7") == ["event_received", "hooks_skipped"])
        #expect(log.last?["reason"] as? String == "configuration_unavailable")
    }

    @Test func anEventWithNoHooksIsLogged() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        await daemon.handle(testEvent(id: "ev-9"), with: try DaemonConfiguration(generation: 1, configText: "mode = \"ask\"\n"), send: Answers().send)
        #expect(try records(logURL).compactMap { $0["type"] as? String } == ["event_received", "no_hooks"])
    }

    @Test func theConfigurationsTimeoutBoundsTheHook() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir, grace: 0.2))
        let configuration = try DaemonConfiguration(generation: 1, configText: """
        mode = "ask"
        timeout_seconds = 1
        [[hook]]
        on = "connection"
        run = 'sleep 30'
        """)
        let started = Date()
        await daemon.handle(testEvent(id: "ev-8", deadlineIn: 30), with: configuration, send: Answers().send)
        #expect(Date().timeIntervalSince(started) < slowRunnerBound)
        #expect(try records(logURL).suffix(2).compactMap { $0["type"] as? String } == ["hook_killed", "hook_no_answer"])
    }

    /// When the extension's connection ends, `blackice daemon` stops its hooks and returns within
    /// the grace period, rather than when the last hook ends on its own.
    @Test func theHooksStopWhenTheIntakeEnds() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let runner = try testRunner(dir, grace: 0.3)
        let daemon = Daemon(log: try EventLog(url: logURL), runner: runner)
        let configuration = try DaemonConfiguration(generation: 1, configText: """
        mode = "ask"
        timeout_seconds = 30
        [[hook]]
        on = "connection"
        run = 'sleep 30'
        """)
        let intake = EndingIntake([.registered(configuration), .event(testEvent(id: "ev-1", deadlineIn: 30), generation: 1)]) {
            (try? String(contentsOf: logURL, encoding: .utf8))?.contains(#""type":"hook_started""#) == true
        }
        await daemon.run(intake, stopHooksWhenIntakeEnds: true)

        let ended = try #require(intake.ended.items.first)
        #expect(Date().timeIntervalSince(ended) < 3, "returned \(Date().timeIntervalSince(ended)) s after the intake ended")
        let log = try records(logURL)
        #expect(types(log, event: "ev-1") == ["event_received", "hook_started", "hook_killed"])
        let killed = try #require(log.last)
        #expect(killed["reason"] as? String == "daemon_stopping" && killed["signal"] as? Int == Int(SIGTERM))
        #expect(runner.runningCount == 0 && runner.waitingCount == 0)
    }

    /// The last line alone is no answer, and the log shows the start of the line before it too, so
    /// that the next answer that does not parse shows how it was laid out. A split approval counts.
    @Test func anUnrecognizedLineIsLoggedWithTheLineBefore() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let answers = Answers()
        await daemon.handle(testEvent(id: "ev-1"), with: try hooks("echo It is the editor.; echo approve; echo 2d"), send: answers.send)
        let missing = try #require(try records(logURL).last)
        #expect(missing["type"] as? String == "hook_no_answer" && missing["reason"] as? String == "unrecognized_line")
        #expect(missing["line_prefix"] as? String == "2d" && missing["previous_prefix"] as? String == "approve")
        #expect(answers.sent.items.isEmpty)

        await daemon.handle(testEvent(id: "ev-2"), with: try hooks("echo It is the editor.; echo approve; echo; echo 24h"),
                            send: answers.send)
        #expect(answers.sent.items.map(\.seconds) == [86_400])
        #expect(try records(logURL).last?["type"] as? String == "hook_answer")
    }

    /// A long stderr keeps its end in the log, where an agent says why it failed.
    @Test func theEndOfALongStderrIsLogged() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        await daemon.handle(testEvent(id: "ev-1"), with: try hooks(#"head -c 10240 /dev/zero | tr "\000" x >&2; echo "FATAL: x" >&2; exit 1"#),
                            send: Answers().send)
        let log = try records(logURL)
        let exited = try #require(log.first { $0["type"] as? String == "hook_exited" })
        let stderr = try #require(exited["stderr"] as? String)
        #expect(stderr.hasPrefix(String(repeating: "x", count: 512) + "\n…\n") && stderr.hasSuffix("xxFATAL: x\n"), "\(stderr)")
        #expect(stderr.count == EventLog.maximumStderrCharacters + 3)
        #expect(exited["stderr_truncated"] as? Bool == true)
        #expect(log.last?["reason"] as? String == "exit_status")
        #expect(!(try String(contentsOf: logURL, encoding: .utf8)).contains(testToken))
    }

    /// Hooks that keep failing are counted, at 3, 10, 30 and so on, with the last line the latest
    /// one wrote to stderr, its colors out, as `status` reads the hook's own record; the first
    /// answer after says the run is over. The hooks keep running all along.
    @Test func hooksFailingInARowAreCounted() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let answers = Answers()
        // A banner first, then the error, in color.
        let failing = try hooks(#"printf "\033[1mfx ask\033[0m 2.4.1\n\nconnecting\n  \033[31mError:\033[0m Auth failed: run login \n\n" >&2; exit 2"#)
        for index in 1...2 { await daemon.handle(testEvent(id: "ev-\(index)"), with: failing, send: answers.send) }
        #expect(try records(logURL).allSatisfy { $0["type"] as? String != "hooks_failing" })
        // The third prints nothing and exits with 0: no answer either.
        await daemon.handle(testEvent(id: "ev-3"), with: try hooks("true"), send: answers.send)
        var log = try records(logURL)
        let third = try #require(log.last)
        let first = try #require(log.first { $0["type"] as? String == "hook_no_answer" })
        #expect(third["type"] as? String == "hooks_failing" && third["count"] as? Int == 3)
        #expect(third["reason"] as? String == "no_line" && third["stderr_line"] as? String == "")
        #expect(third["since"] as? String == first["ts"] as? String)
        for index in 4...10 { await daemon.handle(testEvent(id: "ev-\(index)"), with: failing, send: answers.send) }
        log = try records(logURL)
        #expect(log.filter { $0["type"] as? String == "hooks_failing" }.compactMap { $0["count"] as? Int } == [3, 10])
        let tenth = try #require(log.last)
        #expect(tenth["reason"] as? String == "exit_status" && tenth["stderr_line"] as? String == "Error: Auth failed: run login")
        #expect(tenth["since"] as? String == first["ts"] as? String)
        #expect(types(log, event: "ev-10") == ["event_received", "hook_started", "hook_exited", "hook_no_answer"])
        // The record and the hook's own say the same.
        let exited = try #require(log.last { $0["type"] as? String == "hook_exited" })
        #expect(FailingHooks.lastLine(try #require(exited["stderr"] as? String)) == "Error: Auth failed: run login")
        #expect(FailingHooks.read(url: logURL)?.reason == "Error: Auth failed: run login")

        await daemon.handle(testEvent(id: "ev-11"), with: try hooks("echo deny"), send: answers.send)
        log = try records(logURL)
        #expect(log.last?["type"] as? String == "hooks_recovered" && log.last?["after"] as? Int == 10)
        // A new run counts from 1, and an answer after fewer than 3 writes nothing.
        await daemon.handle(testEvent(id: "ev-12"), with: failing, send: answers.send)
        await daemon.handle(testEvent(id: "ev-13"), with: try hooks("echo deny"), send: answers.send)
        #expect(try records(logURL).filter { ($0["type"] as? String)?.hasPrefix("hooks_") == true }.count == 3)
        #expect(answers.sent.items.count == 2)
    }

    /// A daemon that starts again (the extension restarted, an upgrade, a login) takes up the run
    /// the end of the log shows, from when it began, rather than count from 1; after an answer
    /// there is none to take up.
    @Test func aRunGoesOnWhenTheDaemonStartsAgain() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let answers = Answers()
        let failing = try hooks(#"echo "fx ask: API request failed · HTTP 502" >&2; exit 1"#)
        func counts() throws -> [Int] {
            try records(logURL).filter { $0["type"] as? String == "hooks_failing" }.compactMap { $0["count"] as? Int }
        }
        // To the millisecond, which a time read from the log and written again can lose.
        func since(_ record: [String: Any]?, is date: Date) -> Bool {
            guard let text = record?["since"] as? String, let since = FailingHooks.date(text) else { return false }
            return abs(since.timeIntervalSince(date)) < 0.002
        }
        let runner = try testRunner(dir)
        let first = Daemon(log: try EventLog(url: logURL), runner: runner)
        for index in 1...4 { await first.handle(testEvent(id: "ev-\(index)"), with: failing, send: answers.send) }
        let began = try #require((try records(logURL).first { $0["type"] as? String == "hook_no_answer" }?["ts"] as? String)
            .flatMap(FailingHooks.date))

        let second = Daemon(log: try EventLog(url: logURL), runner: runner)
        for index in 5...10 { await second.handle(testEvent(id: "ev-\(index)"), with: failing, send: answers.send) }
        #expect(try counts() == [3, 10])
        #expect(since(try records(logURL).last, is: began))
        await second.handle(testEvent(id: "ev-11"), with: try hooks("echo deny"), send: answers.send)
        #expect(try records(logURL).last?["after"] as? Int == 10)

        let third = Daemon(log: try EventLog(url: logURL), runner: runner)
        for index in 12...14 { await third.handle(testEvent(id: "ev-\(index)"), with: failing, send: answers.send) }
        #expect(try counts() == [3, 10, 3])
        let log = try records(logURL)
        let anew = try #require(log.first { $0["event"] as? String == "ev-12" && $0["type"] as? String == "hook_no_answer" })
        #expect(since(log.last, is: try #require((anew["ts"] as? String).flatMap(FailingHooks.date))))
    }

    /// Only a hook's own failures count: not its deadline, nor its home changing while it ran.
    @Test func whatCountsAsAFailure() {
        for missing: HookResult.NoAnswer in [.exitStatus(1), .signaled(SIGSEGV), .output(.noLine), .output(.outputTooLong),
                                            .output(.unrecognized(prefix: "x"))] {
            #expect(Daemon.failed(missing), "\(missing)")
        }
        #expect(!Daemon.failed(.deadline) && !Daemon.failed(.unsafeHome("/h/.codex/AGENTS.md")))
        #expect((1...100_000).filter(Daemon.isMilestone) == [3, 10, 30, 100, 300, 1000, 3000, 10_000, 30_000, 100_000])
    }

    /// An answer the extension did not reply to in time may still have been taken: it is logged
    /// apart from a connection that is gone.
    @Test func aSlowReplyIsNotAnUnreachableExtension() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(log: try EventLog(url: logURL), runner: try testRunner(dir))
        let answers = Answers()
        answers.reply = { _ in throw AnswerReplyTimeout(seconds: 10) }
        await daemon.handle(testEvent(id: "ev-1"), with: try hooks("echo deny"), send: answers.send)
        let last = try #require(try records(logURL).last)
        #expect(last["type"] as? String == "answer_refused" && last["reason"] as? String == "reply_timeout")
        #expect("\(AnswerReplyTimeout(seconds: 10))" == "the network extension did not reply to the answer within 10 s")
    }

    @Test func logFailuresAreReportedNotDropped() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let log = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        log.closeForTesting()
        let failures = Recorder<String>()
        let configuration = try DaemonConfiguration(generation: 1, configText: "mode = \"ask\"\n[[hook]]\non = \"connection\"\nrun = 'true'\n")
        let daemon = Daemon(log: log, runner: try testRunner(dir)) { error in
            failures.append("\(error)")
        }
        await daemon.handle(testEvent(), with: configuration, send: Answers().send)
        // event_received, hook_started, hook_exited and hook_no_answer: four records, four reports.
        #expect(failures.items.count == 4)
        #expect(failures.items.allSatisfy { $0.contains("closed") })
    }
}

/// Counts fetches and lets a test hold them until it is ready.
private final class SlowSource: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var answers: [DaemonConfiguration]

    init(_ answers: [DaemonConfiguration]) { self.answers = answers }

    var fetches: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func fetch() async throws -> DaemonConfiguration {
        let answer = next()
        try await Task.sleep(nanoseconds: 100_000_000)
        return answer
    }

    private func next() -> DaemonConfiguration {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

private func plain(_ generation: UInt64) throws -> DaemonConfiguration {
    try DaemonConfiguration(generation: generation, configText: "mode = \"ask\"\n")
}

struct ConfigurationStoreTests {
    @Test func anOlderGenerationNeverReplacesANewerOne() async throws {
        let loaded = Recorder<UInt64>()
        let store = ConfigurationStore(fetch: { try plain(1) }, loaded: { loaded.append($0.generation) })
        await store.offer(try plain(3))
        #expect(await store.offer(try plain(2)).generation == 3)
        #expect(await store.offer(try plain(3)).generation == 3)
        #expect(await store.offer(try plain(4)).generation == 4)
        #expect(loaded.items == [3, 4])
        // A fetch that comes back older leaves the newer one in place, and the caller sees it.
        #expect(try await store.configuration(for: 9).generation == 4)
        #expect(await store.current?.generation == 4)
    }

    @Test func theHeldGenerationIsNotFetchedAgain() async throws {
        let source = SlowSource([try plain(2)])
        let store = ConfigurationStore(fetch: { try await source.fetch() })
        await store.offer(try plain(2))
        #expect(try await store.configuration(for: 2).generation == 2)
        #expect(source.fetches == 0)
    }

    @Test func eventsArrivingTogetherShareOneFetch() async throws {
        let source = SlowSource([try plain(5)])
        let store = ConfigurationStore(fetch: { try await source.fetch() })
        await store.offer(try plain(4))
        let generations = await withTaskGroup(of: UInt64?.self) { group in
            for _ in 0..<8 { group.addTask { try? await store.configuration(for: 5).generation } }
            var all: [UInt64?] = []
            for await generation in group { all.append(generation) }
            return all
        }
        #expect(generations == Array(repeating: 5, count: 8))
        #expect(source.fetches == 1)
    }

    @Test func aJoinedFetchFromBeforeTheChangeIsFollowedByAnother() async throws {
        // The first fetch brings 5; an event of 6 arrives while it is under way.
        let source = SlowSource([try plain(5), try plain(6)])
        let store = ConfigurationStore(fetch: { try await source.fetch() })
        async let five = store.configuration(for: 5)
        try await Task.sleep(nanoseconds: 20_000_000)
        async let six = store.configuration(for: 6)
        #expect(try await five.generation == 5)
        #expect(try await six.generation == 6)
        #expect(source.fetches == 2)
    }

    @Test func aFailedFetchIsReported() async throws {
        let store = ConfigurationStore(fetch: { throw MessageError("registration", "was refused") })
        await #expect(throws: MessageError.self) { try await store.configuration(for: 1) }
        #expect(await store.current == nil)
    }
}

struct DaemonLineTests {
    /// The time in UTC to the millisecond and the PID, before the daemon's own words.
    @Test func aLineSaysWhenAndWhichDaemon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 3, second: 4)))
        #expect(daemonLinePrefix(at: date.addingTimeInterval(0.125), pid: 82988) == "2026-11-14T21:03:04.125Z [82988] blackice daemon: ")

        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        let reader = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
        daemonLine("event log /tmp/x", to: FileHandle(fileDescriptor: ends[1], closeOnDealloc: false), at: date)
        close(ends[1])
        let line = String(decoding: try #require(try reader.readToEnd()), as: UTF8.self)
        #expect(line == "2026-11-14T21:03:04.000Z [\(getpid())] blackice daemon: event log /tmp/x\n")
    }

    /// A write that fails, here to a pipe nobody reads, is dropped: `FileHandle.write(_:)` would
    /// raise an exception and end the daemon.
    @Test func aLineThatCannotBeWrittenIsDropped() throws {
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        // EPIPE rather than SIGPIPE, which would end the test run.
        #expect(fcntl(ends[1], F_SETNOSIGPIPE, 1) == 0)
        let handle = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
        daemonLine("the connection to the network extension ended", to: handle)
        daemonLine(String(repeating: "x", count: 100_000), to: handle)
    }
}

struct UserAccountTests {
    @Test func theCurrentAccountComesFromTheUserDatabase() throws {
        let account = try UserAccount.current()
        let entry = try #require(getpwuid(getuid()))
        #expect(account.uid == getuid())
        #expect(account.name == String(cString: entry.pointee.pw_name))
        #expect(account.home == String(cString: entry.pointee.pw_dir))
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0)
        #expect(account.temporaryDirectory == buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        #expect(account.temporaryDirectory.hasPrefix("/"))
    }

    @Test func pathsFollowTheAccount() throws {
        let account = try fakeAccount()
        #expect(DaemonPaths.eventLog(home: account.homeURL).path == "/Users/test/Library/Logs/blackice/events.jsonl")
        #expect(DaemonPaths.logDirectory(home: account.homeURL).path == "/Users/test/Library/Logs/blackice")
        #expect(DaemonPaths.hookDirectory(temporary: account.temporaryURL).path == "/var/folders/xy/abc/T/blackice-hooks")
    }

    @Test func oddValuesAreRefused() {
        let bad: [(String, String, String)] = [
            ("", "/Users/test", "/tmp/"), ("a b", "/Users/test", "/tmp/"), ("a=b", "/Users/test", "/tmp/"),
            ("test", "Users/test", "/tmp/"), ("test", "/Users/te\nst", "/tmp/"), ("test", "/Users/test", "tmp"),
            ("test", "/Users/test", ""),
        ]
        for (name, home, temporary) in bad {
            #expect(throws: FileSafetyError.self, "\(name) \(home) \(temporary)") {
                try UserAccount(uid: 501, name: name, home: home, temporaryDirectory: temporary)
            }
        }
    }
}
