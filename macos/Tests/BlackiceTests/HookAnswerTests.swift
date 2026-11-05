import Foundation
import Testing
@testable import BlackiceCore

private func parse(_ text: String, truncated: Bool = false) -> Result<HookAnswer, HookAnswer.Missing> {
    HookAnswer.parse(Data(text.utf8), truncated: truncated)
}

struct HookAnswerTests {
    @Test(arguments: [
        ("deny", HookAnswer.deny),
        ("approve 10m", .approve(seconds: 600)),
        ("approve 1m", .approve(seconds: 60)),
        ("approve 1440m", .approve(seconds: 86_400)),
        ("approve 1h", .approve(seconds: 3600)),
        ("approve 24h", .approve(seconds: 86_400)),
        // The last non-empty line counts, trimmed of the whitespace around it.
        ("I read event.json.\nIt is VS Code reaching its update server.\n\napprove 1h\n\n", .approve(seconds: 3600)),
        ("approve 1h\r\n", .approve(seconds: 3600)),
        ("It is Docker reaching its registry.\r\napprove 10m\r\n", .approve(seconds: 600)),
        ("  \tdeny  \n", .deny),
        ("approve 24h\ndeny", .deny),
    ])
    func answers(_ text: String, _ expected: HookAnswer) {
        #expect(parse(text) == .success(expected), "\(text.debugDescription)")
    }

    @Test(arguments: [
        "Deny", "DENY", "deny.", "`deny`", "**deny**", "deny 10m", "denied",
        "approve", "approve 10", "approve 10s", "approve 0m", "approve 010m", "approve 1441m", "approve 25h",
        "approve 1d", "approve 1.5h", "approve -1h", "approve +1h", "approve  10m", "approve\t10m", "approve 10M",
        "approve 10m please", "approve 10m deny", "verdict: approve 10m", "deny\u{00A0}x",
        "approve 1h\nThat is my answer.",
    ])
    func everythingElseIsNoAnswer(_ text: String) {
        guard case .failure(.unrecognized) = parse(text) else {
            Issue.record("\(text.debugDescription) was taken as \(parse(text))")
            return
        }
    }

    @Test func emptyOutputAndTooMuchOutput() {
        #expect(parse("") == .failure(.noLine))
        #expect(parse("\n  \n\t\r\n") == .failure(.noLine))
        // Cut at the daemon's limit, the real last line is not known.
        #expect(parse("deny\n", truncated: true) == .failure(.outputTooLong))
    }

    @Test func anUnrecognizedLineIsShownOnlyAsAShortPrintablePrefix() {
        #expect(parse("Approved: this is VS Code reaching its own update server") ==
                .failure(.unrecognized(prefix: "Approved: this is VS Cod…")))
        #expect(parse("deny\u{1B}[31m") == .failure(.unrecognized(prefix: "deny?[31m")))
        #expect(parse("approve 1h ✅") == .failure(.unrecognized(prefix: "approve 1h ?")))
        #expect(HookAnswer.shown(String(repeating: "x", count: 24)) == String(repeating: "x", count: 24))
    }

    /// The same limits as `blackice approve --for`.
    @Test func durationsMatchTheCLI() {
        for minutes in [1, 59, 60, 1440] { #expect(ApprovalDuration.seconds("\(minutes)m", units: ["m", "h"]) == minutes * 60) }
        for hours in [1, 24] { #expect(ApprovalDuration.seconds("\(hours)h", units: ["m", "h"]) == hours * 3600) }
        #expect(ApprovalDuration.seconds("30s", units: ["m", "h"]) == nil)
        #expect(ApprovalDuration.seconds("30s") == 30)
        #expect(ApprovalDuration.seconds("86400s") == ApprovalTable.maximumSeconds)
        for bad in ["86401s", "1441m", "25h", "0m", "", "m"] { #expect(ApprovalDuration.seconds(bad) == nil, "\(bad)") }
    }

    @Test func onlyAHookThatExitedWithZeroAnswers() {
        func result(_ outcome: HookResult.Outcome, _ stdout: String = "deny\n", truncated: Bool = false) -> HookResult {
            HookResult(hookLine: 1, outcome: outcome, stderr: "", stderrTruncated: false, duration: 1,
                       stdout: Data(stdout.utf8), stdoutTruncated: truncated)
        }
        #expect(result(.exited(status: 0)).answer == .success(.deny))
        #expect(result(.exited(status: 1)).answer == .failure(.exitStatus(1)))
        #expect(result(.signaled(signal: 11)).answer == .failure(.signaled(11)))
        #expect(result(.timedOut(signal: 15)).answer == .failure(.deadline))
        #expect(result(.exited(status: 0), "deny\n", truncated: true).answer == .failure(.output(.outputTooLong)))
        #expect(result(.exited(status: 0), "").answer == .failure(.output(.noLine)))
        for outcome: HookResult.Outcome in [.dropped(.queueFull), .failedToStart("x"), .refused(found: "unknown")] {
            #expect(result(outcome).answer == nil)
        }
    }
}
