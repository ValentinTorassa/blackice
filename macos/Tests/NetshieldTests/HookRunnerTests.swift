import Darwin
import Foundation
import Testing
@testable import NetshieldCore

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
        cat "$NETSHIELD_EVENT_FILE" > \(quotedPath(out("file.json"))); \
        printf %s "$NETSHIELD_EVENT_FILE" > \(quotedPath(out("path.txt"))); \
        printf %s "$NETSHIELD_EVENT_ID" > \(quotedPath(out("id.txt"))); \
        stat -f %Lp "$NETSHIELD_EVENT_FILE" > \(quotedPath(out("file-mode.txt"))); \
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
        let command = "cat > \(quotedPath(stdin)); cat $NETSHIELD_EVENT_FILE > /dev/null; env > \(quotedPath(environment))"
        let results = try await testRunner(dir).run([hook(command)], for: event, timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])
        #expect(!fileExists(marker), "the event's text ran as a command")
        #expect(try Data(contentsOf: stdin) == event.jsonData())
        #expect(try HookEvent.decode(Data(contentsOf: stdin)).host == host)
        #expect(!(try read(environment)).contains("touch"))
    }

    @Test func theEnvironmentIsExplicitAndHasNoToken() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let parent = ["HOME": "/Users/test", "PATH": "/usr/bin:/bin", "AWS_SECRET_ACCESS_KEY": "do-not-pass",
                      "NETSHIELD_EVENT_FILE": "/tmp/forged", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"]
        let passed = HookRunner.environment(from: parent)
        #expect(passed == ["HOME": "/Users/test", "PATH": "/usr/bin:/bin"])
        #expect(HookRunner.environment(from: [:]) == ["PATH": HookRunner.defaultPath])

        // Even NETSHIELD_ values handed in by the caller are replaced.
        let runner = try testRunner(dir, environment: passed.merging(["NETSHIELD_EVENT_ID": "forged"]) { a, _ in a })
        let output = dir.appendingPathComponent("env.txt")
        let results = await runner.run([hook("/usr/bin/env > \(quotedPath(output))")], for: testEvent(), timeoutSeconds: 10)
        #expect(results.map(\.outcome) == [.exited(status: 0)])
        let lines = Set(try read(output).split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=/Users/test"))
        #expect(lines.contains("NETSHIELD_EVENT_ID=ev-0a1b2c3d"))
        #expect(lines.contains { $0.hasPrefix("NETSHIELD_EVENT_FILE=") && !$0.hasSuffix("/tmp/forged") })
        let text = try read(output)
        for absent in [testToken, "do-not-pass", "forged", "DYLD_INSERT_LIBRARIES"] {
            #expect(!text.contains(absent), "\(absent) reached the hook's environment")
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
        let hooks = (1...3).map { hook("sleep 1", line: $0) }
        let results = await runner.run(hooks, for: testEvent(), timeoutSeconds: 10)
        #expect(results.filter { $0.outcome == .exited(status: 0) }.count == 2)
        #expect(results.filter { $0.outcome == .dropped(.concurrencyLimit) }.count == 1)
        #expect(runner.runningCount == 0)

        // The slots come back once the hooks finish.
        let again = await runner.run(Array(hooks.prefix(2)), for: testEvent(), timeoutSeconds: 10)
        #expect(again.map(\.outcome) == [.exited(status: 0), .exited(status: 0)])
    }

    @Test func theLimitCountsHooksFromEveryEvent() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let runner = try testRunner(dir, limit: 1)
        async let first = runner.run([hook("sleep 1")], for: testEvent(id: "ev-1"), timeoutSeconds: 10)
        async let second = runner.run([hook("sleep 1")], for: testEvent(id: "ev-2"), timeoutSeconds: 10)
        let outcomes = (await first + second).map(\.outcome)
        #expect(outcomes.filter { $0 == .exited(status: 0) }.count == 1)
        #expect(outcomes.filter { $0 == .dropped(.concurrencyLimit) }.count == 1)
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

    @Test func progressReportsStartAndFinish() async throws {
        let dir = try makePrivateDirectory()
        defer { removeTree(dir) }
        let progress = Recorder<String>()
        let results = try await testRunner(dir).run([hook("echo oops >&2; exit 2", line: 7)], for: testEvent(),
                                                     timeoutSeconds: 10) { update in
            switch update {
            case .started(let line, let pid): progress.append("started \(line) \(pid > 0)")
            case .finished(let result): progress.append("finished \(result.hookLine) \(result.outcome)")
            }
        }
        #expect(results.first?.stderr == "oops\n")
        #expect(progress.items == ["started 7 true", "finished 7 exited(status: 2)"])
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
