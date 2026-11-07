import Darwin
import Foundation
import Testing
@testable import BlackiceCore

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
            (.dropped(.deadlineNear), "hook_dropped", "reason", "deadline_near"),
            (.dropped(.eventEnded), "hook_dropped", "reason", "event_ended"),
            (.dropped(.queueFull), "hook_dropped", "reason", "queue_full"),
            (.failedToStart("no shell"), "hook_failed", "error", "no shell"),
            (.refused(found: "invalid_signature"), "hook_refused", "found", "invalid_signature"),
            (.unsafeHome(path: "/h/.codex/AGENTS.md"), "hook_refused", "path", "/h/.codex/AGENTS.md"),
        ]
        for (outcome, type, key, value) in cases {
            let data = try EventLog.encode(.hookFinished(eventID: "ev-1", result(outcome)), at: Date())
            let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(record["type"] as? String == type)
            #expect(record["hook_line"] as? Int == 9)
            #expect(record["duration_ms"] as? Int == 1235)
            #expect("\(record[key] ?? "missing")" == "\(value)")
            #expect(record["stderr"] == nil)
            #expect(record["waited_ms"] == nil)
        }
    }

    /// Why a hook was refused, and why an answer did not count: the signature, or the agent's home.
    @Test func aRefusalSaysWhy() throws {
        func record(_ entry: LogRecord) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: EventLog.encode(entry, at: Date())) as? [String: Any])
        }
        #expect(try record(.hookFinished(eventID: "ev-1", result(.refused(found: "x"))))["reason"] as? String == "signature")
        let home = try record(.hookFinished(eventID: "ev-1", result(.unsafeHome(path: "/h/.fx/AGENTS.md"))))
        #expect(home["reason"] as? String == "agent_home" && home["path"] as? String == "/h/.fx/AGENTS.md")
        let voided = try record(.hookNoAnswer(eventID: "ev-1", hookLine: 9, .unsafeHome("/h/.fx/AGENTS.md")))
        #expect(voided["type"] as? String == "hook_no_answer" && voided["reason"] as? String == "agent_home")
        #expect(voided["path"] as? String == "/h/.fx/AGENTS.md")
    }

    /// A hook that had to wait for a slot: hook_queued, then waited_ms on its start and its end.
    @Test func aHookThatWaitedSaysSo() throws {
        func record(_ entry: LogRecord) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: EventLog.encode(entry, at: Date())) as? [String: Any])
        }
        let queued = try record(.hookQueued(eventID: "ev-1", hookLine: 9, waiting: 3))
        #expect(queued["type"] as? String == "hook_queued")
        #expect(queued["event"] as? String == "ev-1" && queued["hook_line"] as? Int == 9 && queued["waiting"] as? Int == 3)
        let started = try record(.hookStarted(eventID: "ev-1", hookLine: 9, pid: 42, waited: 12.3456))
        #expect(started["type"] as? String == "hook_started" && started["waited_ms"] as? Int == 12346)
        #expect(try record(.hookStarted(eventID: "ev-1", hookLine: 9, pid: 42))["waited_ms"] == nil)
        let ended = try record(.hookFinished(eventID: "ev-1", HookResult(
            hookLine: 9, outcome: .dropped(.deadlineNear), stderr: "", stderrTruncated: false, duration: 0, waited: 40.5)))
        #expect(ended["type"] as? String == "hook_dropped" && ended["reason"] as? String == "deadline_near")
        #expect(ended["waited_ms"] as? Int == 40500 && ended["duration_ms"] as? Int == 0)
    }

    @Test func configurationAndSkippedHooksHaveTheirRecords() throws {
        let configuration = try DaemonConfiguration(generation: 7, configText: """
        mode = "ask"
        timeout_seconds = 15
        [[hook]]
        on = "connection"
        run = 'SECRET=hunter2 /usr/local/bin/agent'
        """)
        let loaded = try #require(try JSONSerialization.jsonObject(with: EventLog.encode(.configurationLoaded(configuration), at: Date()))
            as? [String: Any])
        #expect(loaded["type"] as? String == "configuration_loaded")
        #expect(loaded["generation"] as? Int == 7 && loaded["hooks"] as? Int == 1 && loaded["timeout_seconds"] as? Int == 15)
        // The run lines stay out of the log.
        #expect(!String(decoding: try EventLog.encode(.configurationLoaded(configuration), at: Date()), as: UTF8.self).contains("hunter2"))

        let skipped = try #require(try JSONSerialization.jsonObject(
            with: EventLog.encode(.hooksSkipped(eventID: "ev-1", reason: "configuration_changed"), at: Date())) as? [String: Any])
        #expect(skipped["type"] as? String == "hooks_skipped")
        #expect(skipped["event"] as? String == "ev-1" && skipped["reason"] as? String == "configuration_changed")
    }

    /// What a hook answered, why it gave no answer, and when the extension did not take it. Never
    /// the hook's output itself, beyond a short prefix of a line that is not an answer.
    @Test func answersAndMissingAnswersHaveTheirRecords() throws {
        func record(_ entry: LogRecord) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: EventLog.encode(entry, at: Date())) as? [String: Any])
        }
        let approved = try record(.hookAnswered(eventID: "ev-1", hookLine: 9, .approve(seconds: 600)))
        #expect(approved["type"] as? String == "hook_answer" && approved["event"] as? String == "ev-1")
        #expect(approved["hook_line"] as? Int == 9 && approved["answer"] as? String == "approve" && approved["seconds"] as? Int == 600)
        let denied = try record(.hookAnswered(eventID: "ev-1", hookLine: 9, .deny))
        #expect(denied["answer"] as? String == "deny" && denied["seconds"] == nil)

        let cases: [(HookResult.NoAnswer, String, String?, Any?)] = [
            (.exitStatus(3), "exit_status", "status", 3),
            (.signaled(SIGSEGV), "signaled", "signal", Int(SIGSEGV)),
            (.deadline, "deadline", nil, nil),
            (.output(.noLine), "no_line", nil, nil),
            (.output(.outputTooLong), "output_too_long", nil, nil),
            (.output(.unrecognized(prefix: "Approved: it is VS Code…")), "unrecognized_line", "line_prefix",
             "Approved: it is VS Code…"),
        ]
        for (missing, reason, key, value) in cases {
            let line = try record(.hookNoAnswer(eventID: "ev-2", hookLine: 4, missing))
            #expect(line["type"] as? String == "hook_no_answer" && line["event"] as? String == "ev-2")
            #expect(line["hook_line"] as? Int == 4 && line["reason"] as? String == reason)
            if let key { #expect("\(line[key] ?? "missing")" == "\(value ?? "")") }
            #expect(Set(line.keys).subtracting(["ts", "type", "event", "hook_line", "reason"]).count == (key == nil ? 0 : 1))
        }

        let refused = try record(.answerRefused(eventID: "ev-3", hookLine: 2, reason: "token_spent"))
        #expect(refused["type"] as? String == "answer_refused" && refused["reason"] as? String == "token_spent")
        #expect(refused["event"] as? String == "ev-3" && refused["hook_line"] as? Int == 2)

        // A result's stdout is never written, only what it means.
        let finished = try record(.hookFinished(eventID: "ev-1", HookResult(
            hookLine: 9, outcome: .exited(status: 0), stderr: "", stderrTruncated: false, duration: 1,
            stdout: Data("my reasons, at length\napprove 10m\n".utf8))))
        #expect(!finished.values.contains { "\($0)".contains("reasons") || "\($0)".contains("approve") })
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
