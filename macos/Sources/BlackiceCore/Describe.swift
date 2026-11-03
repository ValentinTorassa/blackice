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
