import Foundation
import BlackiceCore

/// What `blackice status` found, gathered by the system side and worded here, where tests reach.
public struct StatusReport {
    public enum Filter {
        /// Another product's content filter is configured; blackice leaves it alone.
        case foreign(String)
        case notConfigured
        /// Saved, but turned off (in System Settings › Network › Filters, or by another tool).
        case disabled
        /// Saved and on, but the configuration in it cannot be read.
        case unreadable
        case on(ProviderConfiguration)
    }

    public let filter: Filter
    /// Whether launchd has the daemon's LaunchAgent loaded.
    public let daemonRunning: Bool
    /// What the extension answered over XPC; nil when it did not answer.
    public let pending: PendingReply?

    public init(filter: Filter, daemonRunning: Bool, pending: PendingReply?) {
        self.filter = filter
        self.daemonRunning = daemonRunning
        self.pending = pending
    }
}

extension CLI {
    public static func statusLines(_ report: StatusReport) -> [String] {
        let configuration: ProviderConfiguration
        switch report.filter {
        case .foreign(let owner):
            return ["blackice is off: another product (\(owner)) has this Mac's content filter, and blackice leaves it alone."]
        case .notConfigured:
            return ["blackice is off. Start it with: blackice start"]
        case .disabled:
            return ["blackice is off: its filter is turned off in System Settings › Network › Filters.",
                    "Turn it back on with: blackice start"]
        case .unreadable:
            return ["blackice is on, but its saved configuration cannot be read. Load yours again with: blackice start"]
        case .on(let saved):
            configuration = saved
        }
        let config = configuration.config
        var lines = ["blackice is on, in \(configuration.mode.rawValue) mode: \(configuration.mode.explanation)."]
        func row(_ label: String, _ value: String) { lines.append("  " + label.padding(toLength: 11, withPad: " ", startingAt: 0) + value) }
        row("rules", config.allow.isEmpty ? "none" : Describe.count(config.allow.count, "app") + " allowed in every mode")
        if config.hooks.isEmpty {
            row("hooks", report.daemonRunning ? "none (the daemon is running, with nothing to run)" : "none")
        } else {
            row("hooks", "\(config.hooks.count), " + (report.daemonRunning ? "run by the daemon"
                : "but the daemon is not running: blackice agent install"))
        }
        if configuration.mode == .ask { row("answer in", "\(config.timeoutSeconds) s, or the connection is denied") }
        guard let pending = report.pending else {
            row("filter", "not answering. If blackice was just upgraded, restart the Mac.")
            return lines
        }
        let waiting = pending.events.reduce(0) { $0 + $1.connections }
        if pending.events.isEmpty {
            row("waiting", "nothing")
        } else {
            row("waiting", "\(Describe.count(pending.events.count, "app and host", "apps and hosts"))" +
                (waiting > 0 ? " (\(Describe.count(waiting, "connection")))" : "") + ": blackice pending")
        }
        if !pending.approvals.isEmpty { row("approvals", Describe.count(pending.approvals.count, "approval")) }
        return lines
    }

    /// After a mode change: what it means, and what the new mode needs.
    public static func modeChangedLines(_ configuration: ProviderConfiguration, daemonRunning: Bool) -> [String] {
        var lines = ["✓ Now in \(configuration.mode.rawValue) mode: \(configuration.mode.explanation)."]
        guard configuration.mode == .ask else { return lines }
        if configuration.config.hooks.isEmpty {
            lines.append("See what is waiting with blackice pending, and answer with blackice approve or deny.")
        } else if !daemonRunning {
            lines.append("Your hooks need the daemon, which is not running: blackice agent install")
        }
        return lines
    }

    /// After the first start, once macOS has the extension: where to go next.
    public static func firstStartLines(_ configuration: ProviderConfiguration, daemonRunning: Bool) -> [String] {
        var lines = ["", "Next:", "  blackice status          what blackice is doing"]
        if configuration.mode != .ask {
            lines.append("  blackice mode ask        hold new connections until you, or a hook, answers")
        } else {
            lines.append("  blackice pending         connections waiting for an answer")
        }
        if !configuration.config.hooks.isEmpty, !daemonRunning {
            lines.append("  blackice agent install   run your hooks for those connections")
        }
        lines.append("Docs: https://blackice-macos.vercel.app/docs")
        return lines
    }
}
