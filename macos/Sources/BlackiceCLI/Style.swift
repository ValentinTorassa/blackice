import Foundation

/// Emphasis for a person at a terminal: bold step titles and things to click, green checks,
/// commands in cyan. Plain text when standard output is not a terminal, with NO_COLOR set, or
/// with TERM=dumb, so logs, pipes and tests see exactly the words.
public enum Style {
    /// Set once by main.swift, before any output.
    nonisolated(unsafe) public static var enabled = false

    public static func enableForTerminal(environment: [String: String] = ProcessInfo.processInfo.environment) {
        enabled = isatty(STDOUT_FILENO) == 1 && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
    }

    static func wrap(_ text: String, _ code: String, enabled: Bool = Style.enabled) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// A step's title.
    public static func heading(_ text: String) -> String { wrap(text, "1") }
    /// What the person clicks or turns on.
    public static func action(_ text: String) -> String { wrap(text, "1") }
    /// A command to type.
    public static func command(_ text: String) -> String { wrap(text, "36") }
    /// Something that worked, after a check mark.
    public static func done(_ text: String) -> String { wrap("✓", "32") + " " + text }
}
