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
        #expect(record["app_script"] == nil)
    }

    /// The script an interpreter ran is kept with the event, as the agent saw it.
    @Test func anInterpretersScriptIsLogged() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let app = HookEvent.App(AppIdentity.cdhash(String(repeating: "ab", count: 20)), path: "/opt/homebrew/bin/python3",
                                script: "/opt/homebrew/bin/aws")
        try log.append(.eventReceived(try HookEvent.connection(app: app, host: "sts.amazonaws.com", ip: "203.0.113.7",
                                                               port: 443, deadline: Date().addingTimeInterval(30))))
        let record = try #require(try lines(url).first)
        #expect(record["app_script"] as? String == "/opt/homebrew/bin/aws")
        #expect(record["app_cdhash"] as? String == String(repeating: "ab", count: 20))
        #expect(record["app_title"] == nil)
        // With no script to read, the title the process gave itself.
        let npm = HookEvent.App(AppIdentity.cdhash(String(repeating: "ab", count: 20)), path: "/opt/homebrew/bin/node",
                                title: "npm run wait")
        try log.append(.eventReceived(try HookEvent.connection(app: npm, host: "registry.npmjs.org", ip: "203.0.113.8",
                                                               port: 443, deadline: Date().addingTimeInterval(30))))
        let second = try #require(try lines(url).last)
        #expect(second["app_title"] as? String == "npm run wait" && second["app_script"] == nil)
    }

    @Test func eachOutcomeHasItsRecordType() throws {
        let cases: [(HookResult.Outcome, String, String, Any)] = [
            (.exited(status: 2), "hook_exited", "status", 2),
            (.signaled(signal: SIGSEGV), "hook_signaled", "signal", Int(SIGSEGV)),
            (.timedOut(signal: SIGKILL), "hook_killed", "signal", Int(SIGKILL)),
            (.dropped(.deadlineNear), "hook_dropped", "reason", "deadline_near"),
            (.dropped(.eventEnded), "hook_dropped", "reason", "event_ended"),
            (.dropped(.queueFull), "hook_dropped", "reason", "queue_full"),
            (.dropped(.daemonStopping), "hook_dropped", "reason", "daemon_stopping"),
            (.timedOut(signal: SIGTERM), "hook_killed", "reason", "deadline"),
            (.timedOut(signal: SIGTERM, reason: .daemonStopping), "hook_killed", "reason", "daemon_stopping"),
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
            #expect(record["waited_ms"] == nil && record["slept_ms"] == nil)
        }
    }

    /// A hook the Mac slept through says for how long, beside its reason, which stays `deadline`.
    @Test func aHookThatSleptSaysHowLong() throws {
        func record(_ outcome: HookResult.Outcome, slept: TimeInterval) throws -> [String: Any] {
            let result = HookResult(hookLine: 9, outcome: outcome, stderr: "", stderrTruncated: false, duration: 2.5, slept: slept)
            return try #require(try JSONSerialization.jsonObject(with: EventLog.encode(.hookFinished(eventID: "ev-1", result), at: Date()))
                as? [String: Any])
        }
        let killed = try record(.timedOut(signal: SIGTERM), slept: 3600.25)
        #expect(killed["type"] as? String == "hook_killed" && killed["reason"] as? String == "deadline")
        #expect(killed["slept_ms"] as? Int == 3_600_250 && killed["duration_ms"] as? Int == 2500)
        let exited = try record(.exited(status: 0), slept: 61)
        #expect(exited["type"] as? String == "hook_exited" && exited["slept_ms"] as? Int == 61_000)
        // A second or less is the clocks' own drift, and a clock set back is no sleep.
        #expect(try record(.exited(status: 0), slept: 1)["slept_ms"] == nil)
        #expect(try record(.timedOut(signal: SIGKILL), slept: -30)["slept_ms"] == nil)
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

        // The start of the line before an unrecognized one, when there is one.
        let shaped = try record(.hookNoAnswer(eventID: "ev-2", hookLine: 4, .output(.unrecognized(prefix: "24 h")),
                                              previousPrefix: "approve"))
        #expect(shaped["line_prefix"] as? String == "24 h" && shaped["previous_prefix"] as? String == "approve")
        #expect(try record(.hookNoAnswer(eventID: "ev-2", hookLine: 4, .exitStatus(1), previousPrefix: "x"))["previous_prefix"] == nil)

        let refused = try record(.answerRefused(eventID: "ev-3", hookLine: 2, reason: "token_spent"))
        #expect(refused["type"] as? String == "answer_refused" && refused["reason"] as? String == "token_spent")
        #expect(refused["event"] as? String == "ev-3" && refused["hook_line"] as? Int == 2)

        // A result's stdout is never written, only what it means.
        let finished = try record(.hookFinished(eventID: "ev-1", HookResult(
            hookLine: 9, outcome: .exited(status: 0), stderr: "", stderrTruncated: false, duration: 1,
            stdout: Data("my reasons, at length\napprove 10m\n".utf8))))
        #expect(!finished.values.contains { "\($0)".contains("reasons") || "\($0)".contains("approve") })
    }

    /// Its start and its end, where an agent says why it failed, with a mark where it was cut.
    @Test func longStderrIsCut() throws {
        let stderr = String(repeating: "h", count: 1000) + String(repeating: "m", count: 3000) + "FATAL: x"
        let data = try EventLog.encode(.hookFinished(eventID: "ev-1", result(.exited(status: 1), stderr: stderr)), at: Date())
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["stderr"] as? String == String(repeating: "h", count: 512) + "\n…\n" + String(repeating: "m", count: 1528) + "FATAL: x")
        #expect(record["stderr_truncated"] as? Bool == true)
        // At the limit it is whole.
        let whole = String(repeating: "w", count: EventLog.maximumStderrCharacters)
        let kept = try #require(try JSONSerialization.jsonObject(
            with: EventLog.encode(.hookFinished(eventID: "ev-1", result(.exited(status: 1), stderr: whole)), at: Date())) as? [String: Any])
        #expect(kept["stderr"] as? String == whole && kept["stderr_truncated"] == nil)
    }

    /// The records `blackice status` and the menu read when hooks keep failing: exactly these keys.
    @Test func failingHooksHaveTheirRecords() throws {
        let since = Date(timeIntervalSince1970: 1_794_690_184.5)
        let failing = try #require(try JSONSerialization.jsonObject(with: EventLog.encode(
            .hooksFailing(count: 10, reason: "exit_status", stderrLine: "Error: not logged in", since: since), at: Date())) as? [String: Any])
        #expect(Set(failing.keys) == ["ts", "type", "count", "reason", "stderr_line", "since"])
        #expect(failing["type"] as? String == "hooks_failing" && failing["count"] as? Int == 10)
        #expect(failing["reason"] as? String == "exit_status" && failing["stderr_line"] as? String == "Error: not logged in")
        #expect(failing["since"] as? String == "2026-11-14T21:03:04.500Z")
        let recovered = try #require(try JSONSerialization.jsonObject(with: EventLog.encode(.hooksRecovered(after: 12), at: Date()))
            as? [String: Any])
        #expect(Set(recovered.keys) == ["ts", "type", "after"])
        #expect(recovered["type"] as? String == "hooks_recovered" && recovered["after"] as? Int == 12)
    }

    /// A write that stops part of the way, as on a full disk, leaves a piece of a record: the next
    /// record starts on a line of its own. One that wrote nothing leaves no empty line.
    @Test func aRecordCutShortIsNotGluedToTheNext() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        try log.append(.noHooks(eventID: "ev-1"))
        let calls = Recorder<Int>()
        log.writeBytes = { fd, bytes in
            calls.append(bytes.count)
            guard calls.items.count == 1 else {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(fd, bytes.baseAddress, bytes.count / 2)
        }
        #expect(throws: FileSafetyError.self) { try log.append(.noHooks(eventID: "ev-2")) }
        log.writeBytes = { _, _ in
            errno = ENOSPC
            return -1
        }
        #expect(throws: FileSafetyError.self) { try log.append(.noHooks(eventID: "ev-3")) }
        log.writeBytes = { fd, bytes in Darwin.write(fd, bytes.baseAddress, bytes.count) }
        try log.append(.noHooks(eventID: "ev-4"))
        try log.append(.noHooks(eventID: "ev-5"))

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5 && lines.last == "", "\(text)")
        #expect(lines[1].hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) == nil)
        let events = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .compactMap { $0["event"] as? String }
        #expect(events == ["ev-1", "ev-4", "ev-5"])
    }

    /// A log deleted or moved away while the daemon runs is created again at its path, with the
    /// same checks: a symlink put there instead is refused.
    @Test func theLogFollowsItsPath() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        try log.append(.noHooks(eventID: "ev-1"))

        #expect(unlink(url.path) == 0)
        try log.append(.noHooks(eventID: "ev-2"))
        #expect(try lines(url).map { $0["event"] as? String } == ["ev-2"])
        #expect(try permissions(url) == 0o600)

        let moved = dir.appendingPathComponent("events.jsonl.0")
        #expect(rename(url.path, moved.path) == 0)
        try log.append(.noHooks(eventID: "ev-3"))
        #expect(try lines(url).map { $0["event"] as? String } == ["ev-3"])
        #expect(try lines(moved).map { $0["event"] as? String } == ["ev-2"])

        let elsewhere = dir.appendingPathComponent("elsewhere")
        #expect(FileManager.default.createFile(atPath: elsewhere.path, contents: Data()))
        #expect(unlink(url.path) == 0 && symlink(elsewhere.path, url.path) == 0)
        #expect(throws: FileSafetyError.self) { try log.append(.noHooks(eventID: "ev-4")) }
        #expect(try Data(contentsOf: elsewhere).isEmpty)
        // Once the path is a file of its own again, records go there.
        #expect(unlink(url.path) == 0)
        try log.append(.noHooks(eventID: "ev-5"))
        #expect(try lines(url).map { $0["event"] as? String } == ["ev-5"])
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
