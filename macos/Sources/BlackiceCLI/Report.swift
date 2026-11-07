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
        "blackice was upgraded to build \(app), but macOS still runs build \(running)'s network extension. " +
            "blackice start finishes the upgrade."
    }
}

/// What the filter said after `start` or `mode` saved a configuration.
public enum Activation: Equatable, Sendable {
    /// It decides with the configuration saved.
    case active
    /// It answered, deciding with another configuration, or with none.
    case other(ActiveConfiguration?)
    /// It did not answer.
    case noAnswer

    /// What a reply from the filter says about `saved`; nil for no reply.
    public init(_ reply: PendingReply?, saved: ProviderConfiguration) {
        guard let reply else { self = .noAnswer; return }
        self = reply.active?.matches(saved) == true ? .active : .other(reply.active)
    }
}

extension CLI {
    public static func statusLines(_ report: StatusReport) -> [String] {
        let configuration: ProviderConfiguration
        switch report.filter {
        case .foreign(let owner):
            return ["blackice is off: another product (\(Describe.terminalSafe(owner))) has this Mac's content filter."]
        case .notConfigured:
            return ["blackice is off. Start it: blackice start"]
        case .disabled:
            return ["blackice is off: its filter is turned off in System Settings › Network › Filters. blackice start turns it on."]
        case .unreadable:
            return ["blackice is on, but its saved configuration cannot be read. Load yours again: blackice start"]
        case .on(let saved):
            configuration = saved
        }
        let config = configuration.config
        var lines = ["blackice is on in \(configuration.mode.rawValue) mode"]
        // The filter keeps the configuration it has when it refuses the saved one.
        if let pending = report.pending, pending.active.map({ !$0.matches(configuration) }) ?? true {
            lines = [pending.active.map {
                "blackice is on, but its filter decides in \($0.mode.rawValue) mode (generation \($0.generation)), " +
                    "not with the saved \(configuration.mode.rawValue) mode (generation \(configuration.generation))."
            } ?? "blackice is on, but its filter holds no configuration.", "  Load yours again: blackice start"]
        }
        func row(_ label: String, _ value: String) { lines.append("  " + label.padding(toLength: 11, withPad: " ", startingAt: 0) + value) }
        let ask = configuration.mode == .ask
        if ask { row("answers", answeringLine(config)) }
        if let pending = report.pending {
            if !pending.events.isEmpty {
                row("waiting", Describe.count(pending.events.count, "app and host", "apps and hosts") + ": blackice pending")
            } else if ask {
                row("waiting", "nothing")
            }
            // Dropped with no event, so they never show as waiting.
            if !pending.denials.isEmpty {
                row("denied", Describe.count(pending.denials.count, "app and host", "apps and hosts") +
                    " a moment ago, dropped without asking: blackice pending")
            }
        }
        row("rules", config.allow.isEmpty ? "none" : "\(config.allow.count)")
        if let approvals = report.pending?.approvals, !approvals.isEmpty { row("approvals", "\(approvals.count)") }
        if ask { row("timeout", "\(config.timeoutSeconds) s") }
        if !config.activeHooks.isEmpty, !report.daemonRunning { row("daemon", "not running, so no hook runs: blackice agent install") }
        // What a first start whose agent setup did not finish leaves: on, filtering nothing.
        if configuration.mode == .acceptAll, config.hooks.isEmpty {
            row("next", "blackice agent connect fx, or blackice mode ask")
        }
        if report.pending == nil {
            if let upgrade = report.upgrade {
                row("filter", "still build \(upgrade.running), and this app is build \(upgrade.app): blackice start finishes the upgrade")
            } else {
                row("filter", "not answering; if blackice was just upgraded, restart the Mac")
            }
        }
        return lines
    }

    /// Who answers in ask mode, for `status`: "Claude Code", "Claude Code; also connected: fx".
    static func answeringLine(_ config: BlackiceConfig) -> String {
        let answering = config.answering
        let others = answering.agents.filter { answering.answerer != .agent($0) }.map(\.title)
        switch answering.answerer {
        case .agent(let instructions)?:
            return instructions.title + (others.isEmpty ? "" : "; also connected: \(listed(others))")
        case .you?:
            return (config.activeHooks.isEmpty ? "you, with blackice pending" : "your hooks") +
                (others.isEmpty ? "" : "; connected: \(listed(others))")
        case nil:
            return listed(answering.agents.map(\.title)) + ", each with a hook"
        }
    }

    /// Ask mode and who answers in it, or the other mode alone: "ask mode, Claude Code answers".
    static func modeSummary(_ configuration: ProviderConfiguration) -> String {
        guard configuration.mode == .ask else { return "\(configuration.mode.rawValue) mode" }
        let config = configuration.config
        switch config.answering.answerer {
        case .agent(let instructions)?: return "ask mode, \(instructions.title) answers"
        case .you? where config.activeHooks.isEmpty: return "ask mode, you answer: blackice pending"
        case .you?: return "ask mode, your hooks answer"
        case nil: return "ask mode, \(listed(config.answering.agents.map(\.title))) answer"
        }
    }

    /// Why `blackice mode ask --agent NAME` cannot switch to that agent under `config`, or nil.
    public static func answererRefusal(_ answerer: Answerer, config: BlackiceConfig) -> String? {
        guard case .agent(let instructions) = answerer, !config.answering.agents.contains(instructions) else { return nil }
        return "\(instructions.title) is not connected. Connect it first: blackice agent connect \(instructions.rawValue)"
    }

    /// After a mode change: the mode, who answers, and what is missing for that.
    public static func modeChangedLines(_ configuration: ProviderConfiguration, daemonRunning: Bool) -> [String] {
        var lines = [Style.done("Now in \(modeSummary(configuration))")]
        if configuration.mode == .ask, !configuration.config.activeHooks.isEmpty, !daemonRunning {
            lines.append("  The hooks need the daemon, which is not running: blackice agent install")
        }
        return lines
    }

    /// `blackice mode` with nothing to change.
    public static func alreadyLine(_ configuration: ProviderConfiguration) -> String {
        "Already in \(modeSummary(configuration))."
    }

    /// Why the filter is not known to decide with `saved` after start or mode saved it, and what to
    /// do; empty when it does.
    public static func notActiveLines(_ saved: ProviderConfiguration, _ activation: Activation) -> [String] {
        let log = "  /usr/bin/log show --last 5m --style compact --predicate 'subsystem == \"\(BlackiceIdentifiers.logSubsystem)\"'"
        switch activation {
        case .active:
            return []
        case .noAnswer:
            return ["\(saved.mode.rawValue) mode is saved, but blackice's filter did not answer, so whether it is in force is not known.",
                    "Check with blackice status. If blackice was just upgraded, restart the Mac."]
        case .other(nil):
            return ["blackice's filter holds no configuration, so \(saved.mode.rawValue) mode is not in force. Its log says why:", log]
        case .other(let active?):
            return ["blackice's filter did not load generation \(saved.generation): it decides in \(active.mode.rawValue) mode " +
                    "(generation \(active.generation)). Its log says why:", log]
        }
    }

    /// 0 when the filter decides with what was saved, 69 when it did not answer, 70 when it holds
    /// another configuration.
    public static func activationStatus(_ activation: Activation) -> Int32 {
        switch activation {
        case .active: return ExitCode.success
        case .noAnswer: return ExitCode.unavailable
        case .other: return ExitCode.software
        }
    }

    /// Before start's Touch ID: what it keeps from a switch made with `blackice mode` or the menu,
    /// where `candidate` differs from the file it was started with. Empty when it keeps nothing.
    public static func keptLines(_ candidate: ProviderConfiguration, file: BlackiceConfig) -> [String] {
        var lines: [String] = []
        if candidate.mode != file.mode {
            lines.append("Keeping \(candidate.mode.rawValue) mode from blackice mode or the menu; the file says \(file.mode.rawValue).")
        }
        if let kept = candidate.config.answers, kept != file.answers {
            let who = kept == .you ? "you answering" : "\(kept.title) answering"
            lines.append("Keeping \(who) from blackice mode or the menu; the file says " +
                         (file.answers.map { $0 == .you ? "you" : $0.title } ?? "no one") + ".")
        }
        return lines
    }

    /// After a successful start: the mode, and who answers in ask mode.
    public static func onLines(_ configuration: ProviderConfiguration) -> [String] {
        [Style.done("blackice is on in \(modeSummary(configuration))")]
    }

    /// After the first start, once macOS has the extension: where to go next.
    public static func firstStartLines(_ configuration: ProviderConfiguration, daemonRunning: Bool) -> [String] {
        func row(_ command: String, _ what: String) -> String {
            "  " + Style.command(command.padding(toLength: max(26, command.count), withPad: " ", startingAt: 0)) + " " + what
        }
        var lines = ["", Style.heading("Next"), row("blackice status", "what blackice is doing")]
        if configuration.mode != .ask {
            lines.append(row("blackice mode ask", "hold what no rule covers until you or an agent answers"))
        } else {
            if configuration.config.hooks.isEmpty {
                lines.append(row("blackice agent connect fx", "let fx answer"))
            }
            lines.append(row("blackice pending", "what waits for an answer"))
        }
        if !configuration.config.activeHooks.isEmpty, !daemonRunning {
            lines.append(row("blackice agent install", "run your hooks"))
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
        var lines = ["", Style.heading(setup ? "3 · Allow the network extension" : "Allow the network extension")]
        lines.append(opened ? "  System Settings is open at \(place):" : "  Open System Settings › \(place):")
        lines += steps.enumerated().map { "    \($0.offset + 1). \($0.element)" }
        lines.append("  Waiting for you (up to 10 minutes)…")
        return lines
    }

    /// Said just before blackice saves a content filter for the first time, which macOS asks about.
    public static var filterPrompt: String {
        "macOS now asks whether Blackice may filter network content: click \(Style.action("Allow"))."
    }
}
