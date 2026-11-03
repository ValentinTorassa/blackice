import Foundation
import Testing
@testable import BlackiceCore

/// Hands the daemon a fixed list of events, then ends.
private struct FixedIntake: EventIntake {
    let list: [HookEvent]

    func events() -> AsyncStream<HookEvent> {
        AsyncStream { continuation in
            for event in list { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func records(_ url: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

struct DaemonTests {
    @Test func runsTheHooksForEachEventAndLogsThem() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let config = try BlackiceConfig(text: """
        mode = "ask"
        timeout_seconds = 5

        [[hook]]
        on = "connection"
        run = "cat > \(quotedPath(dir))/$BLACKICE_EVENT_ID.json"
        """)
        let logURL = dir.appendingPathComponent("logs/events.jsonl")
        let daemon = Daemon(config: config, log: try EventLog(url: logURL), runner: try testRunner(dir))
        let events = [testEvent(id: "ev-1"), testEvent(host: "two.example", id: "ev-2")]
        await daemon.run(FixedIntake(list: events))

        for event in events {
            #expect(try Data(contentsOf: dir.appendingPathComponent("\(event.id).json")) == event.jsonData())
        }

        let log = try records(logURL)
        for id in ["ev-1", "ev-2"] {
            let types = log.filter { $0["event"] as? String == id }.compactMap { $0["type"] as? String }
            #expect(types == ["event_received", "hook_started", "hook_exited"], "\(id): \(types)")
        }
        #expect(!(try String(contentsOf: logURL, encoding: .utf8)).contains(testToken))
    }

    @Test func anEventWithNoHooksIsLogged() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let logURL = dir.appendingPathComponent("events.jsonl")
        let daemon = Daemon(config: try BlackiceConfig(text: "mode = \"ask\"\n"), log: try EventLog(url: logURL),
                            runner: try testRunner(dir))
        await daemon.handle(testEvent(id: "ev-9"))
        #expect(try records(logURL).compactMap { $0["type"] as? String } == ["event_received", "no_hooks"])
    }

    @Test func logFailuresAreReportedNotDropped() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let log = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        log.closeForTesting()
        let failures = Recorder<String>()
        let config = try BlackiceConfig(text: "mode = \"ask\"\n[[hook]]\non = \"connection\"\nrun = 'true'\n")
        let daemon = Daemon(config: config, log: log, runner: try testRunner(dir)) { error in
            failures.append("\(error)")
        }
        await daemon.handle(testEvent())
        // event_received, hook_started and hook_exited: three records, three reports.
        #expect(failures.items.count == 3)
        #expect(failures.items.allSatisfy { $0.contains("closed") })
    }
}
