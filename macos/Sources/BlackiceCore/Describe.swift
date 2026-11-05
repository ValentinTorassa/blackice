// What the CLI tells a person about a configuration: plain words, no internals. The `summary`
// properties stay as they are for the logs and the evidence; these are for the terminal.

extension Mode {
    /// One sentence on what the mode does to a new connection.
    public var explanation: String {
        switch self {
        case .acceptAll: return "every connection goes through and is logged"
        case .ask: return "connections no rule covers wait until you, or a hook, answers"
        case .blockAll: return "only connections your rules allow go through"
        }
    }
}

public enum Describe {
    /// "no rules", "1 rule", "3 rules".
    public static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        switch number {
        case 0: return "no \(plural ?? singular + "s")"
        case 1: return "1 \(singular)"
        default: return "\(number) \(plural ?? singular + "s")"
        }
    }

    /// "accept-all mode, no rules, no hooks"; ask mode adds its timeout.
    static func overview(mode: Mode, rules: Int, hooks: Int, timeoutSeconds: Int) -> String {
        var parts = ["\(mode.rawValue) mode", count(rules, "rule"), count(hooks, "hook")]
        if mode == .ask { parts.append("\(timeoutSeconds) s to answer") }
        return parts.joined(separator: ", ")
    }

    /// `/Users/me/.config/x` as `~/.config/x`, for messages.
    public static func path(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Text that an app or another program chose (a bundle's name, a path, a program's output),
    /// made safe to print to a terminal. Control characters (C0, DEL and C1, so ESC and every
    /// escape sequence too), the bidirectional controls and the line and paragraph separators are
    /// written as `\u{…}`, so they can neither move the cursor nor reorder or hide what follows.
    /// Everything else stays as it is.
    public static func terminalSafe(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: unsafeOnTerminal) else { return text }
        var out = ""
        for scalar in text.unicodeScalars {
            if unsafeOnTerminal(scalar) {
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func unsafeOnTerminal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        // Arabic letter mark, left-to-right and right-to-left marks, embeddings, overrides and isolates.
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        case 0x2028, 0x2029: return true
        default: return false
        }
    }
}

extension BlackiceConfig {
    /// "ask mode, 2 rules, 1 hook, 60 s to answer".
    public var overview: String {
        Describe.overview(mode: mode, rules: allow.count, hooks: hooks.count, timeoutSeconds: timeoutSeconds)
    }
}

extension ProviderConfiguration {
    public var overview: String {
        Describe.overview(mode: mode, rules: config.allow.count, hooks: config.hooks.count,
                          timeoutSeconds: config.timeoutSeconds)
    }
}
