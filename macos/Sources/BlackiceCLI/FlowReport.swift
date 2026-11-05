import Foundation
import BlackiceCore

// `blackice report`: the filter's flow lines over the last while, summed up from the public part
// of each line (FlowLogLine.publicText). The host is private in unified logging, so the report
// counts by reason and app, never by host.

/// What a program printed (stdout and stderr together) and its exit status.
public struct LogShowResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public enum FlowLog {
    public static let program = "/usr/bin/log"

    /// `log show` for the filter's flow lines over the last `minutes`.
    public static func showArguments(minutes: Int) -> [String] {
        ["show", "--style", "compact",
         "--predicate", "subsystem == \"\(BlackiceIdentifiers.logSubsystem)\" AND category == \"flows\"",
         "--last", "\(minutes)m"]
    }

    /// Runs /usr/bin/log and collects what it prints. Kept thin on purpose: FlowReport reads the
    /// lines, and tests drive it with sample ones.
    public static func show(minutes: Int) -> LogShowResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = showArguments(minutes: minutes)
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return LogShowResult(status: 127, output: "cannot run \(program): \(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LogShowResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}

/// The public part of one flow line, as `log show --style compact` prints it:
/// `2026-11-05 10:12:01.123 Df com.valentorassa.blackice.filter[13097:c678b]
/// [com.valentorassa.blackice.filter:flows] flow drop timeout app=apple/com.apple.geod <private>`.
public struct FlowLogEntry: Equatable, Sendable {
    public static let verdicts: Set = ["allow", "drop", "hold", "resolve", "ask"]

    public let verdict: String
    public let reason: String
    /// nil on a line from a build that did not log the app yet.
    public let app: String?
    /// In accept-all, what ask mode would have decided (FilterPolicy.dryRun).
    public let would: String?

    static let marker = "[\(BlackiceIdentifiers.logSubsystem):flows] flow "

    public init(verdict: String, reason: String, app: String?, would: String?) {
        self.verdict = verdict
        self.reason = reason
        self.app = app
        self.would = would
    }

    /// nil for anything that is not one of the filter's flow lines: the header, another
    /// subsystem's line, a control line.
    public init?(line: Substring) {
        guard let start = line.range(of: Self.marker)?.upperBound else { return nil }
        let fields = line[start...].split(separator: " ")
        guard fields.count >= 2, Self.verdicts.contains(String(fields[0])) else { return nil }
        verdict = String(fields[0])
        reason = String(fields[1])
        var app: String?
        var would: String?
        // Then `app=` and `would=`, and the JSON, which shows as <private>.
        for field in fields.dropFirst(2) {
            if app == nil, field.hasPrefix("app=") {
                app = String(field.dropFirst(4))
            } else if would == nil, field.hasPrefix("would=") {
                would = String(field.dropFirst(6))
            } else {
                break
            }
        }
        self.app = app
        self.would = would
    }
}

/// Counts of flow lines by what `blackice report` shows.
public struct FlowReport: Equatable, Sendable {
    /// Apps listed under one heading; the rest are summed on one row.
    static let appsShown = 5
    static let noApp = "(app not logged)"

    public private(set) var total = 0
    /// Drops: reason -> app -> lines.
    public private(set) var dropped: [String: [String: Int]] = [:]
    /// Connections the app closed before writing a byte, by app: logged as drops, but nothing was cut.
    public private(set) var closedEarly: [String: Int] = [:]
    /// Ask mode: flows paused to ask, by app.
    public private(set) var asked: [String: Int] = [:]
    /// Accept-all lines that carry a dry run of ask mode.
    public private(set) var dryRuns = 0
    public private(set) var wouldAsk: [String: Int] = [:]
    /// `drop:<reason>` without `drop:` -> app -> lines.
    public private(set) var wouldDrop: [String: [String: Int]] = [:]
    public private(set) var wouldReadServerName: [String: Int] = [:]
    /// What lets a flow through without asking, by the first part of its reason (`rule_line_3`
    /// for `rule_line_3;server_name`).
    public private(set) var wouldPass: [String: Int] = [:]

    public init(logText: String) {
        for line in logText.split(separator: "\n") {
            if let entry = FlowLogEntry(line: line) { add(entry) }
        }
    }

    mutating func add(_ entry: FlowLogEntry) {
        total += 1
        let app = entry.app ?? Self.noApp
        switch entry.verdict {
        case "drop" where entry.reason == "closed_before_hello": closedEarly[app, default: 0] += 1
        case "drop": dropped[entry.reason, default: [:]][app, default: 0] += 1
        case "ask": asked[app, default: 0] += 1
        default: break
        }
        guard let would = entry.would else { return }
        dryRuns += 1
        if would == "ask" {
            wouldAsk[app, default: 0] += 1
        } else if would.hasPrefix("drop:") {
            wouldDrop[String(would.dropFirst(5)), default: [:]][app, default: 0] += 1
        } else if would == "read_server_name" {
            wouldReadServerName[app, default: 0] += 1
        } else {
            wouldPass[String(would.prefix { $0 != ";" }), default: 0] += 1
        }
    }

    /// What `blackice report` prints; `last` is the span as typed back, "1h" or "30m".
    public func summary(last: String) -> [String] {
        guard total > 0 else {
            return ["blackice's filter logged no connection in the last \(last). Is it on? blackice status"]
        }
        var lines = ["blackice's filter, last \(last): \(Describe.count(total, "flow line")).", ""]
        let drops = dropped.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        if drops == 0 {
            lines.append("Dropped: none")
        } else {
            lines.append("Dropped: \(drops)")
            lines += Self.byReason(dropped, indent: "  ")
        }
        if !closedEarly.isEmpty {
            lines += ["", "Closed by the app before it sent anything: \(closedEarly.values.reduce(0, +))"]
            lines.append("  Nothing was cut: an app that opens two connections at once uses one and closes the other.")
            lines += Self.rows(closedEarly, indent: "  ")
        }
        if !asked.isEmpty {
            lines += ["", "Paused to ask: \(asked.values.reduce(0, +))"]
            lines += Self.rows(asked, indent: "  ")
        }
        guard dryRuns > 0 else { return lines }
        lines += ["", "In accept-all, what ask mode would have done with \(dryRuns) of them:"]
        let asks = wouldAsk.values.reduce(0, +)
        lines.append("  asked about: \(asks)")
        lines += Self.rows(wouldAsk, indent: "    ")
        let wouldDrops = wouldDrop.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        if wouldDrops > 0 {
            lines.append("  dropped: \(wouldDrops)")
            lines += Self.byReason(wouldDrop, indent: "    ")
        }
        let reads = wouldReadServerName.values.reduce(0, +)
        if reads > 0 {
            lines.append("  read the server name first, then decided on it: \(reads)")
            lines += Self.rows(wouldReadServerName, indent: "    ")
        }
        let passes = wouldPass.values.reduce(0, +)
        if passes > 0 {
            let parts = Self.sorted(wouldPass).map { "\(Self.shown($0.key)) \($0.value)" }
            lines.append("  passed without asking: \(passes) (" + parts.joined(separator: ", ") + ")")
        }
        lines.append("  Accept-all looks nothing up and reads no DNS answers: every address is taken to match its")
        lines.append("  host, and a connection with no host name from the system is judged by its address.")
        return lines
    }

    /// A heading per reason with its apps under it, the reasons with the most lines first.
    static func byReason(_ counts: [String: [String: Int]], indent: String) -> [String] {
        let totals = counts.mapValues { $0.values.reduce(0, +) }
        return sorted(totals).flatMap { reason, count in
            ["\(indent)\(shown(reason)): \(count)"] + rows(counts[reason] ?? [:], indent: indent + "  ")
        }
    }

    /// One row per app, the most lines first, counts aligned; past `appsShown`, one row for the rest.
    static func rows(_ counts: [String: Int], indent: String) -> [String] {
        var entries = sorted(counts).map { (label: shown($0.key), count: $0.value) }
        if entries.count > appsShown {
            let rest = entries[(appsShown - 1)...]
            let label = "\(rest.count) more apps"
            entries = Array(entries.prefix(appsShown - 1)) + [(label, rest.reduce(0) { $0 + $1.count })]
        }
        let width = entries.map { String($0.count).count }.max() ?? 1
        return entries.map { entry in
            let count = String(entry.count)
            return indent + String(repeating: " ", count: width - count.count) + count + "  " + entry.label
        }
    }

    private static func sorted(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    }

    /// Any process may log under the filter's subsystem, so what a line says is escaped and cut.
    private static func shown(_ text: String) -> String {
        Describe.terminalSafe(text.count > 300 ? String(text.prefix(300)) + "…" : text)
    }
}
