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
    /// Lines that let a connection through or drop it: one per connection.
    public private(set) var decided = 0
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
        if entry.verdict == "allow" || entry.verdict == "drop" { decided += 1 }
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
            return ["blackice's filter logged nothing in the last \(last). Is it on? blackice status"]
        }
        let drops = dropped.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let asks = asked.values.reduce(0, +)
        var lines = ["Last \(last): \(Describe.count(decided, "connection")), \(drops) dropped" + (asks > 0 ? ", \(asks) asked about" : "")]
        if drops > 0 { lines += ["", Style.heading("Dropped")] + Self.byReason(dropped, indent: "  ") }
        if asks > 0 { lines += ["", Style.heading("Asked about")] + Self.rows(asked, indent: "  ") }
        if !closedEarly.isEmpty {
            lines += ["", "Closed by the app before it sent anything, so nothing was cut: \(closedEarly.values.reduce(0, +))"]
        }
        guard dryRuns > 0 else { return lines }
        lines += ["", Style.heading("In ask mode, of these \(dryRuns)")]
        let asksWould = wouldAsk.values.reduce(0, +)
        let dropsWould = wouldDrop.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let reads = wouldReadServerName.values.reduce(0, +)
        let passes = wouldPass.values.reduce(0, +)
        // The four rows share one column of counts; what is under each starts below its words.
        let width = String(max(asksWould, dropsWould, reads, passes)).count
        let under = String(repeating: " ", count: 2 + width + 2 + 2)
        func row(_ count: Int, _ words: String) -> String {
            "  " + String(repeating: " ", count: width - String(count).count) + "\(count)  " + words
        }
        lines.append(row(asksWould, "would wait for an answer"))
        lines += Self.rows(wouldAsk, indent: under)
        if dropsWould > 0 {
            lines.append(row(dropsWould, "would be dropped"))
            lines += Self.byReason(wouldDrop, indent: under)
        }
        if reads > 0 {
            lines.append(row(reads, "would be decided on their server name"))
            lines += Self.rows(wouldReadServerName, indent: under)
        }
        if passes > 0 {
            var groups: [String: Int] = [:]
            for (reason, count) in wouldPass { groups[Self.passGroup(reason), default: 0] += count }
            lines.append(row(passes, "would go through (" + Self.sorted(groups).map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"))
        }
        lines.append("  An estimate: accept-all reads no DNS answers.")
        return lines
    }

    /// What each drop reason means, as the report says it. A reason it does not know shows as logged.
    static let reasonWords: [String: String] = [
        "timeout": "nobody answered in time",
        "hold_expired": "held past macOS's limit while asking",
        "denied": "denied",
        "denied;remembered": "denied a moment ago",
        "approved;address_mismatch": "approved, but to an address not the host's",
        "no_rule": "no rule",
        "tls_unparsed": "hello not readable as TLS",
        "no_host": "no host name",
        "idle_before_hello": "sent nothing for 2 minutes",
        "server_name_timeout": "no server name within 10 s",
        "server_name_mismatch": "server name another host's",
        "server_name_invalid": "server name not a host name",
        "server_name_unusable": "server name unusable",
        "hostname_invalid": "host name not valid",
        "address_mismatch": "address not the host's",
        "no_address": "no address",
        "invalid_signature": "invalid signature",
        "adhoc_code": "ad hoc signed",
        "unknown_identity": "app not identified",
        "unsupported_socket": "not an internet socket",
        "encrypted_dns": "encrypted DNS",
        "configuration_changed": "configuration changed meanwhile",
        "configuration_unavailable": "no configuration yet",
        "provider_stopped": "filter stopped",
    ]

    /// The words for a reason: known whole, or known up to a `;` with the rest after it in brackets.
    static func words(_ reason: String) -> String {
        if let words = reasonWords[reason] { return words }
        let base = String(reason.prefix { $0 != ";" })
        guard base != reason, let words = reasonWords[base] else { return reason }
        return words + " (" + reason.dropFirst(base.count + 1) + ")"
    }

    /// What lets a flow through without asking, grouped: "rules" for every `rule_line_N`.
    static func passGroup(_ reason: String) -> String {
        if reason.hasPrefix("rule_line_") { return "rules" }
        return ["apple_service": "Apple services", "approval": "approvals", "loopback": "loopback",
                "system_resolver": "DNS", "inbound_not_filtered": "inbound"][reason] ?? reason
    }

    /// An app as the log names it (`TEAMID/com.example.app`, `apple/com.apple.geod`,
    /// `cdhash/8fbec897…`), the way `pending` shows it.
    static func appName(_ label: String) -> String {
        guard let slash = label.firstIndex(of: "/") else { return label }
        let owner = label[..<slash], rest = label[label.index(after: slash)...]
        switch owner {
        case "cdhash": return "ad hoc " + rest.prefix(8)
        case "apple": return String(rest)
        default: return String(rest) + " (" + owner + ")"
        }
    }

    /// A row per reason with its apps under it, the reasons with the most lines first.
    static func byReason(_ counts: [String: [String: Int]], indent: String) -> [String] {
        let totals = counts.mapValues { $0.values.reduce(0, +) }
        let width = totals.values.map { String($0).count }.max() ?? 1
        return sorted(totals).flatMap { reason, count in
            [indent + String(repeating: " ", count: width - String(count).count) + "\(count)  " + shown(words(reason))]
                + rows(counts[reason] ?? [:], indent: indent + String(repeating: " ", count: width + 2) + "  ")
        }
    }

    /// One row per app, the most lines first, counts aligned; past `appsShown`, one row for the rest.
    static func rows(_ counts: [String: Int], indent: String) -> [String] {
        var entries = sorted(counts).map { (label: shown(appName($0.key)), count: $0.value) }
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
