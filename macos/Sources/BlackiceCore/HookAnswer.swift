import Foundation

// How a hook answers (since 0.4.0): on its stdout. The last non-empty line, trimmed of the
// whitespace around it, must be exactly one of
//
//   deny
//   approve <N>m      N from 1 to 1440
//   approve <N>h      N from 1 to 24
//
// and the hook must exit with status 0 before its deadline. Anything else is no answer: the
// connection waits for its deadline and is denied. The line names no app and no host. The daemon
// takes both from the event, so a hook can only answer the event it was given, and sends the
// answer to the extension with the event's token, which the hook never sees.
//
// One split is read as the answer it was meant to be (since 1.0.8): a last line that is a
// duration alone (`24h`, `30m`, as `approve` takes it) right after a line that is exactly
// `approve`, both trimmed, empty lines between them skipped. An agent that breaks its answer
// there would otherwise give none, and the connection would wait for its deadline. Nothing else
// is put together: `deny` or `I approve` before the duration, or a duration alone, is no answer.

/// What a hook answered.
public enum HookAnswer: Equatable, Sendable {
    case approve(seconds: Int)
    case deny

    /// The daemon reads at most this much of a hook's stdout and discards the rest.
    public static let maximumOutputBytes = 65_536
    /// How much of an unrecognized line the event log keeps. The line is model output.
    public static let shownPrefixCharacters = 24

    /// Why a hook's output holds no answer.
    public enum Missing: Error, Equatable, Sendable {
        /// The output went past `maximumOutputBytes`, so its last line is not known.
        case outputTooLong
        /// No non-empty line.
        case noLine
        /// The last line is not an answer; `prefix` is its start, cut and made printable.
        case unrecognized(prefix: String)

        public var reason: String {
            switch self {
            case .outputTooLong: return "output_too_long"
            case .noLine: return "no_line"
            case .unrecognized: return "unrecognized_line"
            }
        }
    }

    /// The answer in what a hook wrote to stdout. `truncated` says the output went past what the
    /// daemon reads. Whether the hook exited with status 0 in time is the caller's to check.
    public static func parse(_ output: Data, truncated: Bool) -> Result<HookAnswer, Missing> {
        guard !truncated else { return .failure(.outputTooLong) }
        let lines = nonEmptyLines(output)
        guard let line = lines.last else { return .failure(.noLine) }
        if line == "deny" { return .success(.deny) }
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        if words.count == 2, words[0] == "approve",
           let seconds = ApprovalDuration.seconds(String(words[1]), units: ["m", "h"]) {
            return .success(.approve(seconds: seconds))
        }
        if lines.count >= 2, lines[lines.count - 2] == "approve",
           let seconds = ApprovalDuration.seconds(line, units: ["m", "h"]) {
            return .success(.approve(seconds: seconds))
        }
        return .failure(.unrecognized(prefix: shown(line)))
    }

    /// The start of the non-empty line before the last one, shown as an unrecognized line is, or
    /// nil when there is none. The log keeps it beside an unrecognized line, so that the next
    /// answer that does not parse shows how its last two lines were laid out.
    public static func previousLinePrefix(_ output: Data) -> String? {
        let lines = nonEmptyLines(output)
        return lines.count >= 2 ? shown(lines[lines.count - 2]) : nil
    }

    /// Each line of the output, trimmed of the whitespace around it, without the empty ones. Any
    /// line break ends a line. Swift reads "\r\n" as one Character, so splitting on "\n" alone
    /// would miss it.
    private static func nonEmptyLines(_ output: Data) -> [String] {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The first characters of a line, printable ASCII only (anything else becomes "?"), with "…"
    /// when it was longer.
    static func shown(_ line: String) -> String {
        let kept = line.unicodeScalars.prefix(shownPrefixCharacters)
            .map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(kept) + (line.unicodeScalars.count > shownPrefixCharacters ? "…" : "")
    }
}

/// Durations such as "30s", "10m" and "1h": a whole number with no leading zero and one unit, at
/// most 24 h (`ApprovalTable.maximumSeconds`). `blackice approve --for` reads them with every unit,
/// a hook's answer with minutes and hours only, so both have the same limits.
public enum ApprovalDuration {
    public static func seconds(_ text: String, units: Set<Character> = ["s", "m", "h"]) -> Int? {
        guard let unit = text.last, units.contains(unit), let factor = ["s": 1, "m": 60, "h": 3600][unit] else { return nil }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.count <= 6, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              digits.first != "0", let value = Int(digits), value * factor <= ApprovalTable.maximumSeconds else { return nil }
        return value * factor
    }
}
