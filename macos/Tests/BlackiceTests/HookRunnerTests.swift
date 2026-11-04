import Darwin
import Foundation
import Testing
@testable import BlackiceCore

private func hook(_ run: String, line: Int = 1) -> Hook { Hook(on: "connection", run: run, line: line) }

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

struct HookRunnerTests {
    @Test func theHookGetsTheSameJSONOnStdinAndInTheFile() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir)
        let event = testEvent()
        let out = { (name: String) in dir.appendingPathComponent(name) }
        let command = """
        cat > \(quotedPath(out("stdin.json"))); \
        cat "$BLACKICE_EVENT_FILE" > \(quotedPath(out("file.json"))); \
        printf %s "$BLACKICE_EVENT_FILE" > \(quotedPath(out("path.txt"))); \
        printf %s "$BLACKICE_EVENT_ID" > \(quotedPath(out("id.txt"))); \
        stat -f %Lp "$BLACKICE_EVENT_FILE" > \(quotedPath(out("file-mode.txt"))); \
        stat -f %Lp . > \(quotedPath(out("dir-mode.txt"))); \
        pwd -P > \(quotedPath(out("cwd.txt")))
        """
        let results = await runner.run([hook(command)], for: event, timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])

        let json = try event.jsonData()
        #expect(try Data(contentsOf: out("stdin.json")) == json)
        #expect(try Data(contentsOf: out("file.json")) == json)
        #expect(try read(out("id.txt")) == event.id)
        #expect(try read(out("file-mode.txt")).trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(try read(out("dir-mode.txt")).trimmingCharacters(in: .whitespacesAndNewlines) == "700")

        // The hook ran inside the event's directory, and the file and the directory are gone.
        let eventFile = URL(fileURLWithPath: try read(out("path.txt")))
        let eventDirectory = eventFile.deletingLastPathComponent()
        #expect(try read(out("cwd.txt")).trimmingCharacters(in: .whitespacesAndNewlines)
                == eventDirectory.path)
        #expect(!fileExists(eventFile))
        #expect(!fileExists(eventDirectory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("work").path).isEmpty)
    }

    @Test(arguments: [
        "$(touch MARKER)",
        "`touch MARKER`",
        "\"; touch MARKER; \"",
        "'; touch MARKER; '",
        "example.com\ntouch MARKER",
    ])
    func hostileFieldsStayData(_ template: String) async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let marker = dir.appendingPathComponent("pwned")
        let host = template.replacingOccurrences(of: "MARKER", with: marker.path)
        let event = HookEvent(id: "ev-0a1b2c3d", token: testToken,
                              app: .init(signingID: host, teamID: nil, path: host),
                              host: host, ip: host, port: 443, deadline: Date().addingTimeInterval(30))
        let stdin = dir.appendingPathComponent("stdin.json")
        let environment = dir.appendingPathComponent("env.txt")
        // Hooks that read the event the usual ways, including an unquoted variable.
        let command = "cat > \(quotedPath(stdin)); cat $BLACKICE_EVENT_FILE > /dev/null; env > \(quotedPath(environment))"
        let results = try await testRunner(dir).run([hook(command)], for: event, timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])
        #expect(!fileExists(marker), "the event's text ran as a command")
        #expect(try Data(contentsOf: stdin) == event.jsonData())
        #expect(try HookEvent.decode(Data(contentsOf: stdin)).host == host)
        #expect(!(try read(environment)).contains("touch"))
    }

    @Test func theEnvironmentIsBuiltFromTheAccountAndHasNoToken() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let built = HookRunner.environment(for: try fakeAccount())
        #expect(built == ["HOME": "/Users/test", "USER": "test", "LOGNAME": "test", "TMPDIR": "/var/folders/xy/abc/T/",
                          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])

        // Even BLACKICE_ values handed in by the caller are replaced.
        let runner = try testRunner(dir, environment: built.merging(["BLACKICE_EVENT_ID": "forged"]) { a, _ in a })
        let output = dir.appendingPathComponent("env.txt")
        let results = await runner.run([hook("/usr/bin/env > \(quotedPath(output))")], for: testEvent(), timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])
        let lines = Set(try read(output).split(separator: "\n").map(String.init))
        for (key, value) in built { #expect(lines.contains("\(key)=\(value)"), "\(key)") }
        #expect(lines.contains("BLACKICE_EVENT_ID=ev-0a1b2c3d"))
        #expect(lines.contains { $0.hasPrefix("BLACKICE_EVENT_FILE=") && $0.hasSuffix("/event.json") })
        // What sh itself adds (PWD, SHLVL, _) is all there is beyond those.
        let names = Set(lines.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(names.subtracting(built.keys).subtracting(["BLACKICE_EVENT_ID", "BLACKICE_EVENT_FILE", "PWD", "SHLVL", "_", "OLDPWD"])
            .isEmpty, "\(names)")
        let text = try read(output)
        for absent in [testToken, "forged"] {
            #expect(!text.contains(absent), "\(absent) reached the hook's environment")
        }
    }

    @Test func theDaemonsOwnEnvironmentIsNotPassedOn() async throws {
        // The real account, the way the daemon builds it; this process's environment has more.
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let account = try UserAccount.current()
        let output = dir.appendingPathComponent("env.txt")
        let results = try await testRunner(dir).run([hook("/usr/bin/env > \(quotedPath(output))")], for: testEvent(),
                                                    timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])
        let lines = Set(try read(output).split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=\(account.home)") && lines.contains("TMPDIR=\(account.temporaryDirectory)"))
        #expect(lines.contains("PATH=\(HookRunner.defaultPath)"))
        for key in ProcessInfo.processInfo.environment.keys
        where !["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "PWD", "SHLVL", "_", "OLDPWD"].contains(key) {
            #expect(!lines.contains { $0.hasPrefix(key + "=") }, "\(key) reached the hook")
        }
    }

    @Test func theDeadlineKillsTheWholeProcessGroup() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let pidFile = dir.appendingPathComponent("child.pid")
        let command = "sleep 30 & echo $! > \(quotedPath(pidFile)); sleep 30"
        let results = try await testRunner(dir).run([hook(command)], for: testEvent(), timeoutSeconds: 1)
        let result = try #require(results.first)
        #expect(result.outcome == .timedOut(signal: SIGTERM))
        #expect(result.duration >= 0.9 && result.duration < 5, "took \(result.duration) s")
        let child = try #require(pid_t(try read(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(processGone(child), "the background sleep survived")
    }

    @Test func sigkillFollowsWhenSigtermIsIgnored() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let results = try await testRunner(dir, grace: 0.3).run([hook("trap '' TERM; sleep 30")], for: testEvent(),
                                                                 timeoutSeconds: 1)
        let result = try #require(results.first)
        #expect(result.outcome == .timedOut(signal: SIGKILL))
        #expect(result.duration >= 1.2 && result.duration < 5, "took \(result.duration) s")
    }

    @Test func whatTheHookLeavesBehindIsKilledWhenItExits() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let pidFile = dir.appendingPathComponent("child.pid")
        // The background sleep also holds stderr open; the runner must not wait for it.
        let command = "sleep 30 & echo $! > \(quotedPath(pidFile)); exit 3"
        let results = try await testRunner(dir).run([hook(command)], for: testEvent(), timeoutSeconds: 10)
        let result = try #require(results.first)
        #expect(result.outcome == .exited(status: 3))
        #expect(result.duration < 3, "took \(result.duration) s")
        let child = try #require(pid_t(try read(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(processGone(child))
    }

    @Test func theEventDeadlineWinsOverALongerTimeout() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let results = try await testRunner(dir).run([hook("sleep 30")], for: testEvent(deadlineIn: 0.8), timeoutSeconds: 60)
        let result = try #require(results.first)
        #expect(result.outcome == .timedOut(signal: SIGTERM))
        #expect(result.duration < 4, "took \(result.duration) s")
    }

    @Test func nothingRunsAfterTheDeadline() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let progress = Recorder<String>()
        let results = try await testRunner(dir).run([hook("touch \(quotedPath(dir.appendingPathComponent("ran")))")],
                                                     for: testEvent(deadlineIn: -1), timeoutSeconds: 10) { update in
            if case .started = update { progress.append("started") }
        }
        #expect(results.map(\.outcome) == [.dropped(.deadlinePassed)])
        #expect(progress.items.isEmpty)
        #expect(!fileExists(dir.appendingPathComponent("ran")))
    }

    @Test func anOddEventIDIsRefused() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        for id in ["", "ev 1", "ev-1;touch x", "ev-\u{0}", String(repeating: "a", count: 65)] {
            let results = try await testRunner(dir).run([hook("true")], for: testEvent(id: id), timeoutSeconds: 10)
            #expect(results.map(\.outcome) == [.dropped(.invalidEventID)], "\(id.debugDescription)")
        }
    }

    @Test func theConcurrencyLimitHolds() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 2)
        // Each hook counts the hooks alive with it, from files they hold while they run.
        let alive = dir.appendingPathComponent("alive")
        #expect(mkdir(alive.path, 0o700) == 0)
        let counts = dir.appendingPathComponent("counts")
        let command = "touch \(quotedPath(alive))/$$; ls \(quotedPath(alive)) | wc -l >> \(quotedPath(counts)); " +
            "sleep 0.5; rm \(quotedPath(alive))/$$"
        let hooks = (1...5).map { hook(command, line: $0) }
        let results = await runner.run(hooks, for: testEvent(), timeoutSeconds: 10)
        #expect(results.map(\.outcome) == Array(repeating: .exited(status: 0), count: 5))
        let seen = try read(counts).split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(seen.count == 5 && seen.allSatisfy { (1...2).contains($0) }, "\(seen)")
        // Three of the five waited for a slot.
        #expect(results.filter { $0.waited > 0.3 }.count == 3)
        #expect(runner.runningCount == 0 && runner.waitingCount == 0)
    }

    @Test func aHookWaitsForASlotFromAnotherEvent() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1)
        async let first = runner.run([hook("sleep 1")], for: testEvent(id: "ev-1"), timeoutSeconds: 10)
        #expect(await eventually { runner.runningCount == 1 })
        let progress = Recorder<String>()
        let second = await runner.run([hook("true")], for: testEvent(id: "ev-2"), timeoutSeconds: 10) { update in
            switch update {
            case .queued(_, let waiting): progress.append("queued \(waiting)")
            case .started(_, _, let waited): progress.append("started \(waited > 0.5)")
            case .finished(let result): progress.append("finished \(result.outcome)")
            }
        }
        let firstResults = await first
        #expect(firstResults.map(\.outcome) == [.exited(status: 0)] && firstResults[0].waited == 0)
        #expect(second.map(\.outcome) == [.exited(status: 0)])
        #expect(second[0].waited > 0.5 && second[0].duration < 1, "waited \(second[0].waited), ran \(second[0].duration)")
        #expect(progress.items == ["queued 1", "started true", "finished exited(status: 0)"])
    }

    /// One app with many waiting hooks does not hold the others back: the free slots go to the
    /// apps in turn, oldest first within each app.
    @Test func appsTakeTurnsForTheSlots() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1)
        let order = Recorder<String>()
        func launch(_ id: String, _ app: String, _ run: String = "sleep 0.2") -> Task<[HookResult], Never> {
            Task {
                await runner.run([hook(run)], for: testEvent(id: id, app: app), timeoutSeconds: 10) { update in
                    if case .started = update { order.append(id) }
                }
            }
        }
        let tasks = [launch("ev-a1", "com.example.a", "sleep 0.5")]
        #expect(await eventually { runner.runningCount == 1 })
        var queued = tasks
        for (index, (id, app)) in [("ev-a2", "com.example.a"), ("ev-a3", "com.example.a"),
                                   ("ev-b1", "com.example.b")].enumerated() {
            queued.append(launch(id, app))
            #expect(await eventually { runner.waitingCount == index + 1 })
        }
        for task in queued { #expect(await task.value.map(\.outcome) == [.exited(status: 0)]) }
        #expect(order.items == ["ev-a1", "ev-a2", "ev-b1", "ev-a3"])
    }

    @Test func aWaitingHookIsDroppedWhenTooLittleTimeIsLeft() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1, minimumStart: 0.4)
        async let busy = runner.run([hook("sleep 2")], for: testEvent(id: "ev-1"), timeoutSeconds: 10)
        #expect(await eventually { runner.runningCount == 1 })
        let started = Date()
        let late = await runner.run([hook("true")], for: testEvent(id: "ev-2", deadlineIn: 1.2), timeoutSeconds: 10)
        let elapsed = Date().timeIntervalSince(started)
        #expect(late.map(\.outcome) == [.dropped(.deadlineNear)])
        // Given up 0.4 s before its deadline, not when the slot came free.
        #expect((0.5...1.5).contains(late[0].waited) && elapsed < 1.8, "waited \(late[0].waited), took \(elapsed)")
        #expect(runner.waitingCount == 0)
        // With less than the minimum left on arrival it does not wait at all.
        let tooLate = await runner.run([hook("true")], for: testEvent(id: "ev-3", deadlineIn: 0.2), timeoutSeconds: 10)
        #expect(tooLate.map(\.outcome) == [.dropped(.deadlineNear)] && tooLate[0].waited == 0)
        #expect(await busy.map(\.outcome) == [.exited(status: 0)])
    }

    @Test func theQueueIsCapped() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1, waiting: 1)
        async let busy = runner.run([hook("sleep 1")], for: testEvent(id: "ev-1"), timeoutSeconds: 10)
        #expect(await eventually { runner.runningCount == 1 })
        async let waits = runner.run([hook("true")], for: testEvent(id: "ev-2"), timeoutSeconds: 10)
        #expect(await eventually { runner.waitingCount == 1 })
        let full = await runner.run([hook("true")], for: testEvent(id: "ev-3"), timeoutSeconds: 10)
        #expect(full.map(\.outcome) == [.dropped(.queueFull)])
        #expect(await busy.map(\.outcome) == [.exited(status: 0)])
        #expect(await waits.map(\.outcome) == [.exited(status: 0)])
    }

    /// A burst waits without a thread per hook, and every hook in it runs once slots free. Other suites
    /// run alongside and start threads of their own, so the bound leaves room for them: a thread per
    /// waiting hook would add at least 100.
    @Test func aBurstWaitsWithoutAThreadEach() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 2)
        func threads() -> Int32 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            return proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size ? info.pti_threadnum : -1
        }
        let busy = (1...2).map { index in
            Task { await runner.run([hook("sleep 1")], for: testEvent(id: "ev-busy\(index)"), timeoutSeconds: 10) }
        }
        #expect(await eventually { runner.runningCount == 2 })
        let before = threads()
        let burst = (1...100).map { index in
            Task { await runner.run([hook("true")], for: testEvent(id: "ev-\(index)", app: "com.example.app\(index % 3)"),
                                    timeoutSeconds: 10) }
        }
        #expect(await eventually { runner.waitingCount == 100 })
        let during = threads()
        #expect(before > 0 && during - before < 60, "\(before) threads before the burst, \(during) while 100 hooks wait")
        for task in busy + burst { #expect(await task.value.map(\.outcome) == [.exited(status: 0)]) }
        #expect(runner.waitingCount == 0 && runner.runningCount == 0)
    }

    @Test func aWaitingHookIsDroppedWhenItsEventEnds() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1)
        async let busy = runner.run([hook("sleep 1.5")], for: testEvent(id: "ev-1"), timeoutSeconds: 10)
        #expect(await eventually { runner.runningCount == 1 })
        let waiting = Task { await runner.run([hook("true")], for: testEvent(id: "ev-2"), timeoutSeconds: 10) }
        #expect(await eventually { runner.waitingCount == 1 })
        // An end for the running event leaves it alone; the waiting one's end drops it.
        runner.eventEnded("ev-1")
        let ended = Date()
        runner.eventEnded("ev-2")
        #expect(await waiting.value.map(\.outcome) == [.dropped(.eventEnded)])
        #expect(Date().timeIntervalSince(ended) < 1)
        #expect(await busy.map(\.outcome) == [.exited(status: 0)])
        #expect(runner.waitingCount == 0 && runner.runningCount == 0)
    }

    @Test func stderrIsBoundedAndDrained() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let command = "head -c 200000 /dev/zero | tr '\\000' x >&2; echo done"
        let results = try await testRunner(dir).run([hook(command)], for: testEvent(), timeoutSeconds: 10)
        let result = try #require(results.first)
        #expect(result.outcome == .exited(status: 0))
        #expect(result.stderr == String(repeating: "x", count: 4096))
        #expect(result.stderrTruncated)
    }

    @Test func theTokenNeverLeavesInStderr() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        // What fx printed on a real Mac: the full command, and once a copy cut short.
        let command = """
        printf "Running blackice deny --host 'pastebin.com' --token '%s'\\n" "\(testToken)" >&2; \
        printf "Running blackice approve --for 10m --token '%s...\\n" "\(testToken.prefix(32))" >&2
        """
        let results = try await testRunner(dir).run([hook(command)], for: testEvent(), timeoutSeconds: 10)
        let result = try #require(results.first)
        #expect(result.outcome == .exited(status: 0))
        #expect(result.stderr == """
        Running blackice deny --host 'pastebin.com' --token '[token]'
        Running blackice approve --for 10m --token '[token]...

        """)
    }

    @Test(arguments: [
        ("approved apple/com.apple.curl -> api.github.com for 600 s", "approved apple/com.apple.curl -> api.github.com for 600 s"),
        ("token=\(testToken)!", "token=[token]!"),
        ("x\(testToken)y", "[token]"),
        ("cut \(testToken.prefix(8)) and \(testToken.dropFirst(35))", "cut [token] and [token]"),
        ("too short to matter: \(testToken.prefix(7))", "too short to matter: \(testToken.prefix(7))"),
        ("", ""),
    ])
    func redactionHidesOnlyTheToken(text: String, expected: String) {
        #expect(HookRunner.redactToken(testToken, in: text) == expected)
    }

    @Test func progressReportsStartAndFinish() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let progress = Recorder<String>()
        let results = try await testRunner(dir).run([hook("echo oops >&2; exit 2", line: 7)], for: testEvent(),
                                                     timeoutSeconds: 10) { update in
            switch update {
            case .queued: progress.append("queued")
            case .started(let line, let pid, let waited): progress.append("started \(line) \(pid > 0) \(waited)")
            case .finished(let result): progress.append("finished \(result.hookLine) \(result.outcome)")
            }
        }
        #expect(results.first?.stderr == "oops\n")
        #expect(progress.items == ["started 7 true 0.0", "finished 7 exited(status: 2)"])
    }

    @Test func anOpenWorkDirectoryIsRefused() throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let work = dir.appendingPathComponent("work")
        #expect(mkdir(work.path, 0o755) == 0 && chmod(work.path, 0o755) == 0)
        #expect(throws: FileSafetyError.self) { try testRunner(dir) }
        let link = dir.appendingPathComponent("link")
        #expect(symlink(dir.path, link.path) == 0)
        #expect(throws: FileSafetyError.self) {
            try HookRunner(options: .init(workDirectory: link, environment: [:]))
        }
    }
}
