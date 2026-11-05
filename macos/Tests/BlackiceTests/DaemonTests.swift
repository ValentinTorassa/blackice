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
        await daemon.handle(testEvent(id: "ev-6", deadlineIn: 1), with: try hooks("echo approve 1h; sleep 30"), send: answers.send)
        #expect(answers.sent.items.isEmpty)
        let log = try records(logURL)
        #expect(types(log, event: "ev-6").suffix(2) == ["hook_killed", "hook_no_answer"])
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
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try records(logURL).suffix(2).compactMap { $0["type"] as? String } == ["hook_killed", "hook_no_answer"])
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
