import Foundation
import BlackiceCore

/// What `blackice status` found, gathered by the system side and worded here, where tests reach.
public struct StatusReport {
    public enum Filter {
        /// Another product's content filter is configured; blackice leaves it alone.
        case foreign(String)
        case notConfigured
        /// Saved, but turned off: in System Settings › Network › Filters, by another tool, or by a
        /// `blackice start` that turned it off for an upgrade and did not get to turn it on again.
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
    /// Set while macOS has not finished disconnecting a filter that another replaced.
    public let held: HeldDisconnect?
    /// The text of ~/.config/blackice/blackice.toml, to say where what blackice holds differs from
    /// it; nil when there is no such file or it cannot be read.
    public let file: String?
    /// Set from `FailingHooks.threshold` hooks in a row that gave no answer.
    public let failingHooks: FailingHooks?

    public init(filter: Filter, daemonRunning: Bool, pending: PendingReply?, upgrade: UnfinishedUpgrade? = nil,
                held: HeldDisconnect? = nil, file: String? = nil, failingHooks: FailingHooks? = nil) {
        self.filter = filter
        self.daemonRunning = daemonRunning
        self.pending = pending
        self.upgrade = upgrade
        self.held = held
        self.file = file
        self.failingHooks = failingHooks
    }
}

/// macOS has not finished disconnecting a filter that another replaced, and until it has no new
/// connection gets through (FilterDisconnect). `process` is the name of the process whose socket
/// the kernel waits on, when it could be read.
public struct HeldDisconnect: Equatable, Sendable {
    public let disconnect: FilterDisconnect
    public let process: String?

    public init(_ disconnect: FilterDisconnect, process: String?) {
        self.disconnect = disconnect
        self.process = process
    }

    /// "a UDP socket of Python (pid 16441)"; nil when the kernel's list named no process.
    var socket: String? {
        guard let pid = disconnect.pid else { return nil }
        let kind = disconnect.udp ? "a UDP socket" : "a socket"
        return "\(kind) of \(process.map(Describe.terminalSafe) ?? "a process") (pid \(pid))"
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
    /// What `start` says when macOS is still disconnecting the filter the new one replaced.
    public static func heldLines(_ held: HeldDisconnect) -> [String] {
        var lines = ["macOS is still disconnecting the filter that stopped, and until it is done no new connection gets through."]
        if let socket = held.socket {
            lines.append("It waits on \(socket): it is done when that socket closes or sends to another address.")
        }
        lines.append("blackice status says so while it lasts.")
        return lines
    }

    /// What `start` says while it waits, with the filter off, for macOS to finish disconnecting
    /// the filter it turned off, so that the one it starts next is not held with it.
    public static func turnedOffLines(_ held: HeldDisconnect, limit: Int) -> [String] {
        var lines = ["macOS is still disconnecting the filter that was running. Until it is done blackice stays off " +
            "and connections are not checked, for \(limit) s at most."]
        if let socket = held.socket {
            lines.append("It waits on \(socket): it is done when that socket closes or sends to another address.")
        }
        return lines
    }

    /// What `start` says when macOS is still at it after `limit` seconds.
    public static func turnedOffTooLong(limit: Int) -> String {
        "macOS is not done after \(limit) s. Starting the filter anyway."
    }

    /// What `status`, and `mode` before Touch ID, say when the filter is saved but turned off. A
    /// `blackice start` that turned it off for an upgrade turns it on again when it is stopped
    /// part way, and says so when that fails too; until 1.0.8 it did not, and this line named
    /// System Settings alone.
    public static let turnedOffLine = "blackice is off: its filter is turned off (in System Settings, or by a blackice start " +
        "that did not finish). blackice start turns it on."

    /// What `status` prints. `now` and `timeZone` place the time a run of hooks with no answer began.
    public static func statusLines(_ report: StatusReport, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        var lines = filterLines(report, now: now, timeZone: timeZone)
        if let held = report.held {
            lines.append("  " + "network".padding(toLength: 11, withPad: " ", startingAt: 0) +
                "no new connection gets through: macOS is still disconnecting the filter that stopped" +
                (held.socket.map { ", and waits on \($0)" } ?? ""))
        }
        return lines
    }

    private static func filterLines(_ report: StatusReport, now: Date, timeZone: TimeZone) -> [String] {
        let configuration: ProviderConfiguration
        switch report.filter {
        case .foreign(let owner):
            return ["blackice is off: another product (\(Describe.terminalSafe(owner))) has this Mac's content filter."]
        case .notConfigured:
            return ["blackice is off. Start it: blackice start"]
        case .disabled:
            return [turnedOffLine]
        case .unreadable:
            return ["blackice is on, but its saved configuration cannot be read. Load yours again: blackice start"]
        case .on(let saved):
            configuration = saved
        }
        let config = configuration.config
        // The file as it is now, against what blackice holds: a switch made with `blackice mode` or
        // the menu, which the file does not have, and a file changed since the last start, which
        // the next start loads. Until 1.0.8 status said neither, and a start dropped such a switch
        // unsaid.
        let file = report.file.flatMap { try? BlackiceConfig(text: $0) }
        var title = "blackice is on in \(configuration.mode.rawValue) mode"
        if configuration.mode != config.mode, file?.mode != configuration.mode {
            title += " (" + switched + (file.map { "; blackice.toml has \($0.mode.rawValue)" } ?? "") + ")"
        }
        var lines = [title]
        // The filter keeps the configuration it has when it refuses the saved one.
        if let pending = report.pending, pending.active.map({ !$0.matches(configuration) }) ?? true {
            lines = [pending.active.map {
                "blackice is on, but its filter decides in \($0.mode.rawValue) mode (generation \($0.generation)), " +
                    "not with the saved \(configuration.mode.rawValue) mode (generation \(configuration.generation))."
            } ?? "blackice is on, but its filter holds no configuration.", "  Load yours again: blackice start"]
        }
        func row(_ label: String, _ value: String) { lines.append("  " + label.padding(toLength: 11, withPad: " ", startingAt: 0) + value) }
        let ask = configuration.mode == .ask
        if ask {
            if configuration.answersSwitched(from: report.file ?? configuration.configText) != nil,
               file.map({ $0.answering.answerer != config.answering.answerer }) ?? true {
                row("answers", answererName(config) + " (" + switched +
                    (file.map { "; blackice.toml has \(answererName($0))" } ?? "") + ")")
            } else {
                row("answers", answeringLine(config))
            }
        }
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
        // Only where hooks run: in ask mode, under a configuration that has some; and only while
        // the latest failed within the hour, as the menu says it.
        if ask, !config.activeHooks.isEmpty, let failing = report.failingHooks, failing.isRecent(at: now) {
            row("hooks", failingLine(failing, now: now, timeZone: timeZone))
        }
        if !config.activeHooks.isEmpty, !report.daemonRunning { row("daemon", "not running, so no hook runs: blackice agent install") }
        if let text = report.file, !configuration.isStarted(from: text) { row("file", fileLine(file, against: configuration)) }
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

    /// How `status` and `start` say that the mode or who answers was switched in the configuration
    /// blackice holds, never in the file.
    private static let switched = "switched with blackice mode or the menu"

    /// `status`'s line for ~/.config/blackice/blackice.toml when it is not what the last start
    /// loaded: changed since, or another file was started. The next `blackice start` loads it,
    /// and with it its own mode and answerer, which it names where they differ from what blackice
    /// holds; `file` is nil when it does not parse.
    static func fileLine(_ file: BlackiceConfig?, against configuration: ProviderConfiguration) -> String {
        guard let file else {
            let shown = Describe.terminalSafe(Describe.path(defaultConfigPath, home: NSHomeDirectory()))
            return "changed since the last start, and blackice start cannot load it: blackice validate \(shown)"
        }
        var loads: [String] = []
        if file.mode != configuration.mode { loads.append("\(file.mode.rawValue) mode") }
        if file.mode == .ask, configuration.mode != .ask || file.answering.answerer != configuration.config.answering.answerer {
            loads.append(answersPhrase(file))
        }
        return "changed since the last start: blackice start loads it" + (loads.isEmpty ? "" : " (\(loads.joined(separator: ", ")))")
    }

    /// `status`'s line for hooks that keep giving no answer: "failing since 14:02 (297 in a row,
    /// the last at 16:40): fx ask: API request failed · HTTP 502". The times are the first one's
    /// and the latest one's, with the day when that was not today. The reason is cut at 100
    /// characters and made safe for the terminal.
    static func failingLine(_ failing: FailingHooks, now: Date, timeZone: TimeZone) -> String {
        var line = "failing"
        if let since = failing.since {
            line += " since " + clockTime(since, now: now, timeZone: timeZone) + (failing.atLeast ? " or earlier" : "")
        }
        line += " (" + (failing.atLeast ? "at least " : "") + "\(failing.count) in a row"
            + (failing.last.map { ", the last at " + clockTime($0, now: now, timeZone: timeZone) } ?? "") + ")"
        if let reason = failing.reason {
            line += ": " + Describe.terminalSafe(reason.count > 100 ? String(reason.prefix(99)) + "…" : reason)
        }
        return line
    }

    /// "14:02" on the day of `now`, "12 Nov 14:02" another day, in `timeZone`.
    static func clockTime(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(parts.day ?? 1) \(months[((parts.month ?? 1) + 11) % 12]) \(time)"
    }

    /// Who answers under `config`, in a few words: "Claude Code", "you", "fx and Codex, each with
    /// a hook".
    static func answererName(_ config: BlackiceConfig) -> String {
        switch config.answering.answerer {
        case .agent(let instructions)?: return instructions.title
        case .you?: return "you"
        case nil: return listed(config.answering.agents.map(\.title)) + ", each with a hook"
        }
    }

    /// Who answers under `config`, as a clause: "Claude Code answers", "you answer", "your hooks
    /// answer", "fx and Codex answer".
    static func answersPhrase(_ config: BlackiceConfig) -> String {
        switch config.answering.answerer {
        case .agent(let instructions)?: return "\(instructions.title) answers"
        case .you? where config.activeHooks.isEmpty: return "you answer"
        case .you?: return "your hooks answer"
        case nil: return "\(listed(config.answering.agents.map(\.title))) answer"
        }
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

    /// Before start's Touch ID: what it drops of a switch made with `blackice mode` or the menu,
    /// because the file is not the one started last, or has changed since
    /// (`ProviderConfiguration.isStarted(from:)`), and the file wins. `previous` is the
    /// configuration blackice holds. Until 1.0.8 start said only what it kept, so a switch it
    /// dropped went unsaid, and the person found another agent answering, or another mode, with
    /// nothing to say why. Empty when nothing was switched, or `candidate` keeps it.
    public static func droppedLines(previous: ProviderConfiguration?, candidate: ProviderConfiguration,
                                    file: BlackiceConfig) -> [String] {
        guard let previous else { return [] }
        var lines: [String] = []
        if previous.mode != previous.config.mode, candidate.mode != previous.mode {
            lines.append("In \(previous.mode.rawValue) mode now, \(switched); blackice.toml has \(file.mode.rawValue) mode, " +
                         "and this start loads it.")
        }
        if (try? BlackiceConfig.switchedAnswers(in: previous.configText)) != nil,
           candidate.config.answering.answerer != previous.config.answering.answerer {
            // Who answers as status says it, with "you" at the start of a sentence: "You answer",
            // "Your hooks answer"; an agent's name as it is written, "fx answers".
            let phrase = answersPhrase(previous.config)
            let now = previous.config.answering.answerer == .you ? "Y" + phrase.dropFirst() : phrase
            let has = file.answering.answerer == .you ? "you answering" : answererName(file)
            lines.append("\(now) now, \(switched); blackice.toml has \(has), and this start loads it.")
        }
        return lines
    }

    /// What `start` says when it turned the filter off for an upgrade and stopped before it turned
    /// it on with the new configuration: stopped by Control-C, a closed terminal or another signal
    /// (`interrupted`), or by a failure it has said already. It turns the filter back on with the
    /// configuration saved, so that blackice is not left off; `on` says whether that worked.
    public static func putBackLines(interrupted: Bool, on: Bool) -> [String] {
        let what = interrupted ? "blackice start was stopped before it finished" : "blackice start did not finish"
        return [on ? "\(what), so it turned blackice's filter back on with the configuration it had. Run blackice start again."
                   : "\(what), and could not turn blackice's filter back on: blackice is off, and no connection is checked. " +
                     "Run blackice start again."]
    }

    /// What an upgrade's `start` says at the first Control-C or other stop signal while it waits
    /// with the filter off (UpgradeInterruption): it waits on, and turns the filter back on once
    /// the wait is over, unless a second signal says to do it now.
    public static func waitingAfterInterruptLine(_ wait: UpgradeInterruption.Wait) -> String {
        let what: String
        switch wait {
        case .kernel: what = "let the old filter go"
        case .request: what = "finish replacing blackice's network extension"
        }
        return "Waiting for macOS to \(what) before turning blackice back on; press Control-C again to turn it on now."
    }

    /// What `start` says when it is stopped once it has turned the filter on again with the new
    /// configuration: what is left is checking that the filter took it.
    public static let stoppedOnLine = "blackice start was stopped after it turned blackice's filter on with the new configuration. " +
        "blackice status says whether the filter took it."

    /// Why `blackice mode` cannot change anything now, said before Touch ID; nil when it can: the
    /// filter is turned off, so no filter takes what mode would save, or macOS still runs an older
    /// build of the extension, which this app cannot reach to check what it took. Until 1.0.8 mode
    /// asked for Touch ID, saved, and waited 20 s to say that the filter did not answer.
    ///
    /// A change to the mode and answerer blackice already has (`unchanged`) is not refused for an
    /// upgrade, and `upgrade` is not asked: mode says it is already in that mode, as it did before
    /// 1.0.8. It is asked only for a filter that is on. The refusal names what to run and not the
    /// command to run after it, since agent connect and the menu change the mode this way too.
    public static func modeRefusal(enabled: Bool, unchanged: Bool, upgrade: @autoclosure () -> UnfinishedUpgrade?) -> String? {
        guard enabled else { return turnedOffLine }
        guard !unchanged else { return nil }
        return upgrade().map { $0.hint + " Run it, then try again." }
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
