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
            #expect(try Data(contentsOf: dir.appendingPathComponent("g4-\(event.id).json")) == event.jsonData())
        }
        #expect(intake.fetched == 0)
        let log = try records(logURL)
        #expect(log.first?["type"] as? String == "configuration_loaded")
        #expect(log.first?["generation"] as? Int == 4 && log.first?["hooks"] as? Int == 1)
        #expect(log.first?["timeout_seconds"] as? Int == 5)
        for id in ["ev-1", "ev-2"] {
            #expect(types(log, event: id) == ["event_received", "hook_started", "hook_exited"], "\(id)")
        }
        #expect(!(try String(contentsOf: logURL, encoding: .utf8)).contains(testToken))
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
        #expect(types(log, event: "ev-5") == ["event_received", "hook_started", "hook_exited"])
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
        await daemon.handle(testEvent(id: "ev-9"), with: try DaemonConfiguration(generation: 1, configText: "mode = \"ask\"\n"))
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
        await daemon.handle(testEvent(id: "ev-8", deadlineIn: 30), with: configuration)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try records(logURL).last?["type"] as? String == "hook_killed")
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
        await daemon.handle(testEvent(), with: configuration)
        // event_received, hook_started and hook_exited: three records, three reports.
        #expect(failures.items.count == 3)
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
