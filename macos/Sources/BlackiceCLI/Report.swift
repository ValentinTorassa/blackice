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
    /// Set when the extension did not answer because macOS runs another build of it than this app's.
    public let upgrade: UnfinishedUpgrade?

    public init(filter: Filter, daemonRunning: Bool, pending: PendingReply?, upgrade: UnfinishedUpgrade? = nil) {
        self.filter = filter
        self.daemonRunning = daemonRunning
        self.pending = pending
        self.upgrade = upgrade
    }
}

/// Blackice.app was replaced by another build and `blackice start` has not activated its extension
/// yet, so macOS still runs the old build's. Each build's extension listens on its own XPC service
/// name (Peers.machServiceName), so until then this app's commands cannot reach the running one.
public struct UnfinishedUpgrade: Equatable, Sendable {
    /// CFBundleVersion of the extension macOS runs.
    public let running: String
    /// CFBundleVersion of the extension inside this app.
    public let app: String

    /// `running` lists the builds of the extension macOS has enabled and is not uninstalling. nil
    /// unless the app's build is known and every running build is older: none runs, the app's build
    /// runs, or a newer one does, which start would refuse to replace.
    public init?(app: String?, running: [String]) {
        guard let app, let appVersion = ExtensionReplacement.version(app), let other = running.first,
              running.allSatisfy({ ExtensionReplacement.version($0)?.lexicographicallyPrecedes(appVersion) == true })
        else { return nil }
        self.running = other
        self.app = app
    }

    public var hint: String {
        "blackice was upgraded to build \(app), but macOS still runs the network extension of build \(running). " +
            "Run blackice start to finish the upgrade."
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
            if let upgrade = report.upgrade {
                row("filter", "still build \(upgrade.running), and this app is build \(upgrade.app): " +
                    "run blackice start to finish the upgrade")
            } else {
                row("filter", "not answering. If blackice was just upgraded, restart the Mac.")
            }
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

    /// After a successful start: the mode, and what it does on a line of its own.
    public static func onLines(_ configuration: ProviderConfiguration) -> [String] {
        let explanation = configuration.mode.explanation
        return [Style.done("blackice is on, in \(configuration.mode.rawValue) mode."),
                "  " + explanation.prefix(1).uppercased() + explanation.dropFirst() + "."]
    }

    /// After the first start, once macOS has the extension: where to go next.
    public static func firstStartLines(_ configuration: ProviderConfiguration, daemonRunning: Bool) -> [String] {
        func row(_ command: String, _ what: String) -> String {
            "  " + Style.command(command.padding(toLength: max(26, command.count), withPad: " ", startingAt: 0)) + " " + what
        }
        var lines = ["", Style.heading("Next"), row("blackice status", "what blackice is doing")]
        if configuration.mode != .ask {
            lines.append(row("blackice mode ask", "hold new connections until you or a hook answers"))
        } else {
            if configuration.config.hooks.isEmpty {
                lines.append(row("blackice agent connect fx", "let fx answer them"))
            }
            lines.append(row("blackice pending", "connections waiting for an answer"))
        }
        if !configuration.config.hooks.isEmpty, !daemonRunning {
            lines.append(row("blackice agent install", "run your hooks for those connections"))
        }
        lines.append("  Docs: https://blackice-macos.vercel.app/docs")
        return lines
    }
}

/// Where macOS asks the person to allow a system extension, and what to do there. The macOS 27
/// steps were followed on 27.0.1 (3 November 2026): General › Login Items lists apps, and the
/// pane opens scrolled to the end. 15 lists network extensions by category, and 14 asks in
/// Privacy & Security, as Apple laid those versions out.
public enum ExtensionApproval {
    public static func settingsURL(macOS major: Int) -> String {
        major >= 15 ? "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
                    : "x-apple.systempreferences:com.apple.preference.security"
    }

    /// The step that waits for the person: where to go, what to click, numbered.
    public static func lines(macOS major: Int, opened: Bool, setup: Bool) -> [String] {
        let place: String
        let steps: [String]
        switch major {
        case ..<15:
            place = "Privacy & Security"
            steps = ["Scroll down to Security.",
                     "Where it says Blackice was blocked from loading, click \(Style.action("Allow")).",]
        case 15:
            place = "General › Login Items & Extensions"
            steps = ["Under Extensions, click \(Style.action("ⓘ")) next to Network Extensions.",
                     "Turn on \(Style.action("Blackice")), then click \(Style.action("Done")).",]
        default:
            place = "General › Login Items"
            steps = ["Scroll to \(Style.action("Blackice")) in the list and click \(Style.action("ⓘ")) next to it.",
                     "Turn on \(Style.action("Network Extension")), then click \(Style.action("Done")).",]
        }
        var lines = ["", Style.heading(setup ? "3 · Allow the network extension" : "Allow the network extension"), ""]
        lines.append(opened ? "  System Settings is open at \(place). There:" : "  Open System Settings › \(place). There:")
        lines.append("")
        lines += steps.enumerated().map { "    \($0.offset + 1). \($0.element)" }
        lines += ["", "  Waiting for you (up to 10 minutes)…"]
        return lines
    }

    /// Said just before blackice saves a content filter for the first time, which macOS asks about.
    public static var filterPrompt: String {
        "macOS now asks whether Blackice may filter network content: click \(Style.action("Allow"))."
    }
}
