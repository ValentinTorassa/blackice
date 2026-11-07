import Foundation
import BlackiceCore

/// One line of the menu, in order. The AppKit layer turns each into an NSMenuItem. `key` stays the
/// same across refreshes while the line means the same thing, so an open menu is updated in place
/// and rebuilt only when lines come or go.
public struct MenuEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The first line: the mode in words.
        case title
        /// A line that only informs.
        case note
        case section
        case separator
        /// A connection that waits, with Allow and Deny in its submenu.
        case waiting(WaitingEvent)
        /// One line, "Recent: " and the latest decision; the last few in its submenu.
        case recent([RecentLine])
        /// The Mode submenu: Accept All, Ask with each agent or you answering, Block All.
        case modes([ModeChoice])
        case command(MenuCommand)
    }

    public var kind: Kind
    public var key: String
    public var title: String
    /// After the title on the same line, in the secondary color: the seconds left, or how long ago.
    public var detail: String?
    public var enabled: Bool
    public var checked: Bool

    public init(_ kind: Kind, key: String, title: String, detail: String? = nil, enabled: Bool = false,
                checked: Bool = false) {
        self.kind = kind
        self.key = key
        self.title = title
        self.detail = detail
        self.enabled = enabled
        self.checked = checked
    }
}

/// One item of the Mode submenu.
public struct ModeChoice: Equatable, Sendable {
    public let mode: Mode
    /// Who answers, for an Ask item; nil for Accept All and Block All.
    public let answerer: Answerer?
    public let title: String
    /// Under the title, for an agent with no hook yet: how to connect it.
    public let detail: String?
    public let enabled: Bool
    public let checked: Bool
}

/// A waiting connection's event, as its submenu needs it.
public struct WaitingEvent: Equatable, Sendable {
    public let identity: AppIdentity
    public let host: String
    /// The disabled lines at the top of the submenu: the code's identity, the connections, the
    /// address and the path.
    public let lines: [String]
}

/// A decision on one line: "Denied Python → oauth2.googleapis.com", and "4m".
public struct RecentLine: Equatable, Sendable {
    public let title: String
    public let detail: String?
}

public enum MenuCommand: Equatable, Sendable {
    case stop, quit
}

/// An answer from a waiting connection's submenu: what `blackice approve --for` or `blackice deny`
/// sends after Touch ID.
public struct MenuAnswer: Equatable, Sendable {
    public let title: String
    public let kind: AnswerRequest.Kind
    public let seconds: Int?

    public static let all = [
        MenuAnswer(title: "Allow for 10 Minutes", kind: .approve, seconds: 600),
        MenuAnswer(title: "Allow for 1 Hour", kind: .approve, seconds: 3600),
        MenuAnswer(title: "Deny", kind: .deny, seconds: nil),
    ]

    public func request(for event: WaitingEvent) -> AnswerRequest {
        AnswerRequest(kind: kind, app: event.identity, host: event.host, seconds: seconds, token: nil)
    }
}

/// Whether blackice opens at login, as the menu shows it.
public enum LoginState: Equatable, Sendable {
    /// This copy cannot: the reason.
    case unavailable(String)
    case off
    case on
    /// Registered, and waiting for the person to allow it in System Settings.
    case needsApproval
}

/// What the menu shows besides the snapshot.
public struct MenuContext: Equatable, Sendable {
    /// "0.3.2 (build 15)", from Blackice.app's Info.plist; nil for a build outside the app.
    public var version: String?
    public var recent: [RecentDecision]
    /// When the daemon last refused a hook program whose signature did not match, or whose agent's
    /// home had a file blackice did not put there (`hookRefusedForHome`).
    public var hookRefused: Date?
    public var hookRefusedForHome: Bool

    public init(version: String?, recent: [RecentDecision] = [], hookRefused: Date? = nil, hookRefusedForHome: Bool = false) {
        self.version = version
        self.recent = recent
        self.hookRefused = hookRefused
        self.hookRefusedForHome = hookRefusedForHome
    }
}

/// The status item: the mark, dimmed or not, and the count of what waits.
public struct StatusItemLook: Equatable, Sendable {
    public let dimmed: Bool
    /// "" when nothing waits.
    public let count: String
    public let toolTip: String
}

/// The words and the shape of the status item and its menu, from a snapshot.
public enum MenuPresentation {
    /// Waiting connections listed in the menu; `blackice pending` shows the rest.
    public static let waitingLimit = 12
    public static let recentLimit = 5
    /// How long a refused hook stays in the menu.
    public static let refusedHookWindow: TimeInterval = 3600

    /// Full in ask and block-all while the filter answers, and when it answers that it holds no
    /// configuration, since then nothing new passes; dimmed when blackice is off, lets everything
    /// through, or cannot be reached.
    public static func statusItem(_ snapshot: MenuSnapshot) -> StatusItemLook {
        let filtering = snapshot.isOn && snapshot.reachable && snapshot.mode != .acceptAll
        let waiting = snapshot.reachable ? snapshot.pending?.events.count ?? 0 : 0
        let title = header(snapshot).title
        return StatusItemLook(dimmed: !filtering, count: waiting > 0 ? "\(waiting)" : "",
                              toolTip: "blackice: " + title + (waiting > 0 ? ", \(waiting) waiting" : ""))
    }

    /// The first line, and the lines under it that say why or what to do.
    public static func header(_ snapshot: MenuSnapshot) -> (title: String, notes: [String]) {
        switch snapshot.filter {
        case .unknown:
            return ("Checking…", [])
        case .unsignedBuild:
            return ("Not reachable", ["This build is not the signed Blackice.app"])
        case .off:
            return ("Off", ["Turn it on with: blackice start"])
        case .foreign:
            return ("Off", ["Another product has this Mac's content filter"])
        case .unreadable:
            return ("Not reachable", ["Its saved settings cannot be read", "Load them again with: blackice start"])
        case .on(let saved, _):
            // As `blackice status`: what the filter says it decides with, checked against what is saved.
            guard let pending = snapshot.pending else {
                if let upgrade = snapshot.upgrade {
                    return ("Upgrade not finished: run blackice start",
                            ["The filter is still build \(upgrade.running); this app is build \(upgrade.app)"])
                }
                return ("Not reachable", ["Set to \(modeWords(saved.mode)), but the filter does not answer",
                                          "If blackice was just upgraded, restart the Mac"])
            }
            guard let active = pending.active else {
                return ("No configuration", ["The filter lets no new connection through",
                                             "Load yours again with: blackice start"])
            }
            if active == saved { return (modeTitle(active.mode), []) }
            let differs = active.mode == saved.mode ? "" : " (\(modeWords(saved.mode)))"
            return (modeTitle(active.mode), ["The filter did not take the saved settings" + differs,
                                             "Load them again with: blackice start"])
        }
    }

    public static func modeTitle(_ mode: Mode) -> String {
        switch mode {
        case .ask: return "Ask mode"
        case .blockAll: return "Block all"
        case .acceptAll: return "Accept all"
        }
    }

    /// The Mode submenu: Accept All; Ask with each agent blackice knows, enabled when its hook is
    /// in the configuration, then with you answering; Block All. An agent that is not listed before
    /// connecting (`AgentInstructions.listedBeforeConnecting`: Codex, opencode) shows only once it is
    /// connected. The check mark is on the mode the filter decides in, and in ask mode on who
    /// answers. Choosing an item is `blackice mode`, or `blackice mode ask --agent NAME`, with Touch ID.
    public static func modeChoices(_ snapshot: MenuSnapshot, enabled: Bool) -> [ModeChoice] {
        let current = snapshot.mode
        let agents = snapshot.answering?.agents ?? []
        func plain(_ mode: Mode, _ title: String) -> ModeChoice {
            ModeChoice(mode: mode, answerer: nil, title: title, detail: nil, enabled: enabled, checked: current == mode)
        }
        let shown = Answerer.all.filter { answerer in
            guard case .agent(let instructions) = answerer else { return true }
            return instructions.listedBeforeConnecting || agents.contains(instructions)
        }
        let asks = shown.map { answerer -> ModeChoice in
            var connected = true
            if case .agent(let instructions) = answerer { connected = agents.contains(instructions) }
            let title = answerer == .you ? "Ask: You (Manual)" : "Ask: \(answerer.title)"
            return ModeChoice(mode: .ask, answerer: answerer, title: title,
                              detail: connected ? nil : "blackice agent connect \(answerer.name)",
                              enabled: enabled && connected,
                              checked: current == .ask && snapshot.answering?.answerer == answerer)
        }
        return [plain(.acceptAll, "Accept All")] + asks + [plain(.blockAll, "Block All")]
    }

    static func modeWords(_ mode: Mode) -> String {
        switch mode {
        case .ask: return "ask mode"
        case .blockAll: return "block all"
        case .acceptAll: return "accept all"
        }
    }

    /// The menu, top to bottom, as it reads at `now`: only what needs a look or a choice. A line
    /// shows up when something is wrong; the version closes it.
    public static func menu(_ snapshot: MenuSnapshot, _ context: MenuContext, now: Date = Date()) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        let (title, notes) = header(snapshot)
        entries.append(MenuEntry(.title, key: "title", title: title))
        for (index, note) in notes.enumerated() { entries.append(MenuEntry(.note, key: "note.\(index)", title: note)) }

        if let pending = snapshot.pending, !pending.events.isEmpty {
            entries.append(MenuEntry(.separator, key: "waiting.separator", title: ""))
            entries.append(MenuEntry(.section, key: "waiting.section", title: "Waiting"))
            for event in pending.events.prefix(waitingLimit) {
                guard let entry = waiting(event, readAt: snapshot.readAt, now: now) else { continue }
                entries.append(entry)
            }
            if pending.events.count > waitingLimit {
                entries.append(MenuEntry(.note, key: "waiting.more",
                                         title: "\(pending.events.count - waitingLimit) more: blackice pending"))
            }
        }

        entries.append(MenuEntry(.separator, key: "mode.separator", title: ""))
        let recents = context.recent.prefix(recentLimit).map { decision -> RecentLine in
            let (title, detail) = recent(decision, now: now)
            return RecentLine(title: title, detail: detail)
        }
        if let latest = recents.first {
            entries.append(MenuEntry(.recent(recents), key: "recent", title: "Recent: " + latest.title, detail: latest.detail,
                                     enabled: true))
        }
        // `blackice mode` waits until the filter names the new configuration, so it needs a filter
        // that answers.
        let modesEnabled = snapshot.isOn && snapshot.reachable
        entries.append(MenuEntry(.modes(modeChoices(snapshot, enabled: modesEnabled)), key: "mode", title: "Mode",
                                 enabled: modesEnabled))
        if case .on(_, let hooks) = snapshot.filter, let line = hooksLine(hooks: hooks, daemonRunning: snapshot.daemonRunning) {
            entries.append(MenuEntry(.note, key: "hooks", title: line))
        }
        if let refused = context.hookRefused, now.timeIntervalSince(refused) < refusedHookWindow {
            let title = context.hookRefusedForHome ? "A hook did not answer: its agent's home changed"
                : "A hook's signature did not match"
            entries.append(MenuEntry(.note, key: "hooks.refused", title: title,
                                     detail: short(refused, now: now)))
        }
        // `blackice stop`, with Touch ID: the quit item below leaves the filter running, and
        // accept-all still has it read every connection. Off, the header says how to start it.
        if snapshot.isOn {
            entries.append(MenuEntry(.command(.stop), key: "stop", title: "Stop Filtering…", enabled: true))
        }

        entries.append(MenuEntry(.separator, key: "app.separator", title: ""))
        entries.append(MenuEntry(.note, key: "version",
                                 title: context.version.map { "blackice \($0)" } ?? "blackice, a build outside Blackice.app"))
        entries.append(MenuEntry(.command(.quit), key: "quit", title: "Quit Menu", enabled: true))
        return entries
    }

    /// "Safari → example.com:443", "8s" left, and the submenu's lines. nil for an event the
    /// extension sent without a valid app, which `PendingReply.validate` already refuses.
    static func waiting(_ event: PendingSummary, readAt: Date, now: Date) -> MenuEntry? {
        guard let identity = event.app.identity else { return nil }
        let app = MenuText.appName(path: event.path, identity: identity)
        let connections = event.connections == 0 ? "No connection left; an approval covers the next try"
            : event.connections == 1 ? "1 connection waits" : "\(event.connections) connections wait"
        var lines = [MenuText.clean(identity.label, limit: MenuText.lineLimit, keepTail: true), connections,
                     MenuText.clean(event.destination, limit: MenuText.lineLimit, keepTail: true)]
        if let path = event.path { lines.append(MenuText.clean(path, limit: MenuText.lineLimit)) }
        let left = max(0, event.secondsLeft - Int(now.timeIntervalSince(readAt)))
        return MenuEntry(.waiting(WaitingEvent(identity: identity, host: event.host, lines: lines)),
                         key: "waiting." + event.id,
                         title: "\(app) → " + (event.hostIsAddress ? event.hostAndPort : "\(MenuText.host(event.host)):\(event.port)"),
                         detail: "\(left)s", enabled: true)
    }

    /// One line: "Denied Python → oauth2.googleapis.com", and how long ago ("4m").
    static func recent(_ decision: RecentDecision, now: Date) -> (title: String, detail: String?) {
        let what: String
        switch decision.verdict {
        case .approved: what = "Allowed"
        case .denied: what = "Denied"
        case .timedOut, .cancelled: what = "Dropped"
        }
        return ("\(what) \(decision.app) → \(decision.host)", short(decision.date, now: now))
    }

    /// Hooks with no daemon to run them; nil when nothing needs doing.
    static func hooksLine(hooks: Int, daemonRunning: Bool?) -> String? {
        hooks > 0 && daemonRunning == false ? "Hooks won't run: blackice agent install" : nil
    }

    /// "now", "4m", "2h", "3d".
    static func short(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
