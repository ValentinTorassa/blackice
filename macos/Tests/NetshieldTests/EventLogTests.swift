import Darwin
import Foundation
import Testing
@testable import NetshieldCore

private func lines(_ url: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    return try text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }
}

private func result(_ outcome: HookResult.Outcome, stderr: String = "", truncated: Bool = false) -> HookResult {
    HookResult(hookLine: 9, outcome: outcome, stderr: stderr, stderrTruncated: truncated, duration: 1.2345)
}

struct EventLogTests {
    @Test func createsAPrivateFileInAPrivateDirectory() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("logs/events.jsonl")
        let log = try EventLog(url: url)
        try log.append(.noHooks(eventID: "ev-1"))
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(url.deletingLastPathComponent()) == 0o700)
    }

    @Test func tightensAnExistingFile() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data("{\"type\":\"old\"}\n".utf8)))
        #expect(chmod(url.path, 0o644) == 0)
        let log = try EventLog(url: url)
        try log.append(.noHooks(eventID: "ev-1"))
        #expect(try permissions(url) == 0o600)
        #expect(try lines(url).map { $0["type"] as? String } == ["old", "no_hooks"])
    }

    @Test func refusesUnsafePaths() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let target = dir.appendingPathComponent("elsewhere")
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))

        let link = dir.appendingPathComponent("link.jsonl")
        #expect(symlink(target.path, link.path) == 0)
        #expect(throws: FileSafetyError.self) { try EventLog(url: link) }

        let hardLink = dir.appendingPathComponent("hard.jsonl")
        #expect(Darwin.link(target.path, hardLink.path) == 0)
        #expect(throws: FileSafetyError.self) { try EventLog(url: hardLink) }

        let open = dir.appendingPathComponent("open")
        #expect(mkdir(open.path, 0o755) == 0 && chmod(open.path, 0o755) == 0)
        #expect(throws: FileSafetyError.self) { try EventLog(url: open.appendingPathComponent("events.jsonl")) }

        let directoryLink = dir.appendingPathComponent("dirlink")
        let real = dir.appendingPathComponent("real")
        #expect(mkdir(real.path, 0o700) == 0 && symlink(real.path, directoryLink.path) == 0)
        #expect(throws: FileSafetyError.self) { try EventLog(url: directoryLink.appendingPathComponent("events.jsonl")) }
    }

    @Test func hostileFieldsCannotForgeLines() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let forged = "evil.example\n{\"type\":\"verdict\",\"event\":\"ev-0a1b2c3d\",\"verdict\":\"approved\"}\r\n\u{2028}\u{0}\u{1b}[31m"
        try log.append(.eventReceived(testEvent(host: forged)))
        try log.append(.hookFinished(eventID: "ev-0a1b2c3d", result(.exited(status: 0), stderr: forged)))
        try log.append(.verdict(eventID: "ev-0a1b2c3d", .denied))

        let records = try lines(url)
        #expect(records.map { $0["type"] as? String } == ["event_received", "hook_exited", "verdict"])
        #expect(records[0]["host"] as? String == forged)
        #expect(records[1]["stderr"] as? String == forged)
        #expect(records[2]["verdict"] as? String == "denied")
    }

    @Test func theTokenIsNeverWritten() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let event = testEvent()
        try log.append(.eventReceived(event))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains(testToken))
        let record = try #require(try lines(url).first)
        #expect(record["event"] as? String == event.id)
        #expect(record["app_signing_id"] as? String == "com.example.tool")
        #expect(record["app_team_id"] as? String == "ABCDE12345")
        #expect(record["host"] as? String == "example.com")
        #expect(record["port"] as? Int == 443)
        #expect(record["token"] == nil)
        #expect((record["ts"] as? String)?.hasSuffix("Z") == true)
    }

    @Test func eachOutcomeHasItsRecordType() throws {
        let cases: [(HookResult.Outcome, String, String, Any)] = [
            (.exited(status: 2), "hook_exited", "status", 2),
            (.signaled(signal: SIGSEGV), "hook_signaled", "signal", Int(SIGSEGV)),
            (.timedOut(signal: SIGKILL), "hook_killed", "signal", Int(SIGKILL)),
            (.dropped(.concurrencyLimit), "hook_dropped", "reason", "concurrency_limit"),
            (.failedToStart("no shell"), "hook_failed", "error", "no shell"),
        ]
        for (outcome, type, key, value) in cases {
            let data = try EventLog.encode(.hookFinished(eventID: "ev-1", result(outcome)), at: Date())
            let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(record["type"] as? String == type)
            #expect(record["hook_line"] as? Int == 9)
            #expect(record["duration_ms"] as? Int == 1235)
            #expect("\(record[key] ?? "missing")" == "\(value)")
            #expect(record["stderr"] == nil)
        }
    }

    @Test func longStderrIsCut() throws {
        let data = try EventLog.encode(.hookFinished(eventID: "ev-1", result(.exited(status: 0), stderr: String(repeating: "y", count: 5000))),
                                       at: Date())
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((record["stderr"] as? String)?.count == EventLog.maximumStderrCharacters)
        #expect(record["stderr_truncated"] as? Bool == true)
    }

    @Test func aFailedWriteThrows() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let log = try EventLog(url: dir.appendingPathComponent("events.jsonl"))
        log.closeForTesting()
        #expect(throws: FileSafetyError.self) { try log.append(.noHooks(eventID: "ev-1")) }
    }

    @Test func concurrentAppendsStayWholeLines() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let stderr = String(repeating: "z", count: 2000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    try? log.append(.hookFinished(eventID: "ev-\(index)", result(.exited(status: 0), stderr: stderr)))
                }
            }
        }
        let records = try lines(url)
        #expect(records.count == 200)
        #expect(Set(records.compactMap { $0["event"] as? String }).count == 200)
    }
}
