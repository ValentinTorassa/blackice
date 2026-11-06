import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

// `blackice report`: the flow lines `log show --style compact` prints, the summary, and the
// command, with `log show` replaced by sample text.

private let prefix = "2026-11-05 10:12:01.123 Df com.valentorassa.blackice.filter[13097:c678b] " +
    "[com.valentorassa.blackice.filter:flows] flow "

private func line(_ text: String) -> String { prefix + text }

private let tool = "ABCDE12345/com.example.tool"
private let node = "cdhash/3f1c6a0b9e2d4c5a7b8f9e0d1c2b3a4f5e6d7c8b"
private let geod = "apple/com.apple.geod"

/// Stands in for NESystemControl: only `report` is expected.
private final class LogOnly: SystemControlling {
    var asked: [Int] = []
    let result: LogShowResult

    init(_ result: LogShowResult) { self.result = result }

    func flowLog(minutes: Int) -> LogShowResult {
        asked.append(minutes)
        return result
    }

    func start(configText: String, output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func stop(output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func status(output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func pending(output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func runDaemon(output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func installAgent(output: SystemOutput) -> Int32 { ExitCode.unavailable }
    func uninstallAgent(output: SystemOutput) -> Int32 { ExitCode.unavailable }
}

private func run(_ arguments: [String], _ system: SystemControlling) -> (status: Int32, stdout: [String], stderr: [String]) {
    let out = Recorder<String>(), err = Recorder<String>()
    let status = CLI.run(arguments, stdout: { out.append($0) }, stderr: { err.append($0) }, system: system)
    return (status, out.items, err.items)
}

struct FlowReportTests {
    @Test func parsesTheReportCommand() throws {
        #expect(try CLI.parse(["report"]) == .report(minutes: 60))
        #expect(try CLI.parse(["report", "--last", "30m"]) == .report(minutes: 30))
        #expect(try CLI.parse(["report", "--last=2h"]) == .report(minutes: 120))
        #expect(try CLI.parse(["report", "--last", "168h"]) == .report(minutes: 10_080))
        for bad in ["0m", "01h", "169h", "10081m", "1d", "30s", "h", "1.5h", "-1h", " 1h", "1H"] {
            #expect(throws: UsageError.self, "\(bad)") { try CLI.parse(["report", "--last", bad]) }
        }
        #expect(throws: UsageError.self) { try CLI.parse(["report", "1h"]) }
        #expect(throws: UsageError.self) { try CLI.parse(["report", "--for", "1h"]) }
        #expect(CLI.reportSpan(60) == "1h" && CLI.reportSpan(90) == "90m" && CLI.reportSpan(10_080) == "168h")
        #expect(CLI.commandHelp["report"]?.first == "Usage: blackice report [--last 1h]")
    }

    @Test func asksLogShowForTheFilterFlowLines() {
        #expect(FlowLog.showArguments(minutes: 90) == [
            "show", "--style", "compact",
            "--predicate", #"subsystem == "com.valentorassa.blackice.filter" AND category == "flows""#,
            "--last", "90m"])
    }

    @Test func readsTheLinesLogShowPrints() throws {
        let drop = try #require(FlowLogEntry(line: Substring(line("drop tls_unparsed app=\(tool) <private>"))))
        #expect(drop == FlowLogEntry(verdict: "drop", reason: "tls_unparsed", app: tool, would: nil))
        let dry = try #require(FlowLogEntry(line: Substring(line("allow accept_all app=\(geod) would=apple_service;server_name <private>"))))
        #expect(dry.app == geod && dry.would == "apple_service;server_name")
        // With private data shown, the JSON comes last and is not read.
        let shown = try #require(FlowLogEntry(line: Substring(line(#"ask no_rule app=\#(node) {"app":"x","would":"y"}"#))))
        #expect(shown.verdict == "ask" && shown.app == node && shown.would == nil)
        // A build before the app was logged.
        let old = try #require(FlowLogEntry(line: Substring(line("drop timeout <private>"))))
        #expect(old.app == nil && old.reason == "timeout")
        // Not flow lines: the header, a control line, another subsystem, a truncated or unknown line.
        for other in [
            "Timestamp               Ty Process[PID:TID]",
            "2026-11-05 10:12:01.123 Df com.valentorassa.blackice.filter[1:2] [com.valentorassa.blackice.filter:control] control started mode ask",
            "2026-11-05 10:12:01.123 Df other[1:2] [com.example.other:flows] flow drop timeout app=x",
            line("drop"), line("pass something app=x"), "",
        ] {
            #expect(FlowLogEntry(line: Substring(other)) == nil, "\(other)")
        }
    }

    /// What the extension writes is what the report reads.
    @Test func roundTripsTheExtensionsLine() throws {
        let facts = FlowFacts(direction: .outbound, identity: .adHoc(cdhash: testCDHash), internetSocket: true, tcp: true,
                              hostname: "registry.example.com", port: 443, remoteAddress: IPAddress("203.0.113.7"))
        let written = FlowLogLine(flow: facts, verdict: .allow(reason: "accept_all"), snapshot: try policySnapshot(.acceptAll),
                                  would: "read_server_name")
        let read = try #require(FlowLogEntry(line: Substring(line(written.publicText + " <private>"))))
        #expect(read == FlowLogEntry(verdict: "allow", reason: "accept_all", app: "cdhash/" + testCDHash,
                                     would: "read_server_name"))
    }

    @Test func sumsUpDropsAndAsks() {
        let text = (["Timestamp               Ty Process[PID:TID]"]
            + Array(repeating: line("drop timeout app=\(node) <private>"), count: 3)
            + [line("drop timeout app=\(tool) <private>"), line("drop hold_expired app=\(node) <private>"),
               line("drop timeout <private>")]
            + Array(repeating: line("ask no_rule app=\(node) <private>"), count: 2)
            + [line("allow rule_line_3 app=\(tool) <private>"), line("hold reading_server_name app=\(geod) <private>")])
            .joined(separator: "\n")
        #expect(FlowReport(logText: text).summary(last: "1h") == [
            "Last 1h: 7 connections, 6 dropped, 2 asked about",
            "",
            "Dropped",
            "  5  nobody answered in time",
            "       3  ad hoc 3f1c6a0b",
            "       1  (app not logged)",
            "       1  com.example.tool (ABCDE12345)",
            "  1  held past macOS's limit while asking",
            "       1  ad hoc 3f1c6a0b",
            "",
            "Asked about",
            "  2  ad hoc 3f1c6a0b",
        ])
    }

    /// A connection the app closed before it wrote a byte is logged as a drop, but nothing was cut:
    /// on 5 November 2026 Claude Code's spare connections made it look blocked as `tls_unparsed`.
    @Test func connectionsClosedBeforeTheHelloAreNotDrops() {
        let text = ([line("drop closed_before_hello app=\(tool) <private>"),
                     line("allow rule_line_3;server_name app=\(tool) <private>"),
                     line("drop closed_before_hello app=\(tool) <private>"),
                     line("drop tls_unparsed app=\(node) <private>")])
            .joined(separator: "\n")
        #expect(FlowReport(logText: text).summary(last: "1h") == [
            "Last 1h: 4 connections, 1 dropped",
            "",
            "Dropped",
            "  1  hello not readable as TLS",
            "       1  ad hoc 3f1c6a0b",
            "",
            "Closed by the app before it sent anything, so nothing was cut: 2",
        ])
        let none = FlowReport(logText: line("drop closed_before_hello app=\(tool) <private>")).summary(last: "1h")
        #expect(none.first == "Last 1h: 1 connection, 0 dropped" && !none.contains("Dropped"))
    }

    /// A connection held for its hello that stayed quiet for 2 minutes is a drop of its own reason,
    /// apart from a hello that started and did not finish in time.
    @Test func idleConnectionsAreDropsOfTheirOwn() {
        let text = ([line("drop idle_before_hello app=\(node) <private>"),
                     line("drop idle_before_hello app=\(node) <private>"),
                     line("drop server_name_timeout app=\(tool) <private>")])
            .joined(separator: "\n")
        #expect(FlowReport(logText: text).summary(last: "1h") == [
            "Last 1h: 3 connections, 3 dropped",
            "",
            "Dropped",
            "  2  sent nothing for 2 minutes",
            "       2  ad hoc 3f1c6a0b",
            "  1  no server name within 10 s",
            "       1  com.example.tool (ABCDE12345)",
        ])
    }

    @Test func sumsUpTheDryRunOfAskMode() {
        let apps = (1...7).map { "apple/com.apple.service\($0)" }
        var lines = Array(repeating: line("allow accept_all app=\(node) would=ask <private>"), count: 12)
        lines += apps.map { line("allow accept_all app=\($0) would=ask <private>") }
        lines += [line("allow accept_all app=\(tool) would=drop:no_host <private>"),
                  line("allow accept_all app=apple/com.apple.curl would=read_server_name <private>"),
                  line("allow accept_all app=\(geod) would=apple_service;server_name <private>"),
                  line("allow accept_all app=\(geod) would=apple_service <private>"),
                  line("allow loopback app=\(tool) would=loopback <private>"),
                  // A build before the dry run: counted as a line, not in the dry run.
                  line("allow accept_all <private>")]
        let summary = FlowReport(logText: lines.joined(separator: "\n")).summary(last: "30m")
        #expect(summary == [
            "Last 30m: 25 connections, 0 dropped",
            "",
            "In ask mode, of these 24",
            "  19  would wait for an answer",
            "        12  ad hoc 3f1c6a0b",
            "         1  com.apple.service1",
            "         1  com.apple.service2",
            "         1  com.apple.service3",
            "         4  4 more apps",
            "   1  would be dropped",
            "        1  no host name",
            "             1  com.example.tool (ABCDE12345)",
            "   1  would be decided on their server name",
            "        1  com.apple.curl",
            "   3  would go through (Apple services 2, loopback 1)",
            "  An estimate: accept-all reads no DNS answers.",
        ])
        #expect(summary.allSatisfy { $0.count <= 78 })
    }

    @Test func whatOtherProgramsLogIsEscaped() {
        let report = FlowReport(logText: line("drop timeout app=evil\u{1B}[2J <private>"))
        #expect(report.summary(last: "1h").contains("       1  evil\\u{1b}[2J"))
    }

    @Test func reportRunsLogShowAndPrintsTheSummary() {
        let system = LogOnly(LogShowResult(status: 0, output: line("drop timeout app=\(tool) <private>") + "\n"))
        let result = run(["report", "--last", "2h"], system)
        #expect(result.status == ExitCode.success && result.stderr.isEmpty && system.asked == [120])
        #expect(result.stdout.first == "Last 2h: 1 connection, 1 dropped")
        #expect(result.stdout.contains("       1  com.example.tool (ABCDE12345)"))

        let quiet = run(["report"], LogOnly(LogShowResult(status: 0, output: "Timestamp               Ty Process[PID:TID]\n")))
        #expect(quiet.status == ExitCode.success)
        #expect(quiet.stdout == ["blackice's filter logged nothing in the last 1h. Is it on? blackice status"])
    }

    @Test func aFailedLogShowSaysWhy() {
        let failed = run(["report"], LogOnly(LogShowResult(status: 64, output: "log: Couldn't parse predicate\n")))
        #expect(failed.status == ExitCode.software && failed.stdout.isEmpty)
        #expect(failed.stderr == ["blackice report: /usr/bin/log show exited with status 64: log: Couldn't parse predicate"])
        let missing = run(["report"], LogOnly(LogShowResult(status: 127, output: "cannot run /usr/bin/log: no such file")))
        #expect(missing.status == ExitCode.unavailable)
    }
}
