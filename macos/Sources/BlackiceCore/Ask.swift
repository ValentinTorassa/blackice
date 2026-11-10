import Foundation

// Ask mode's state inside the extension, as plain values with tests (phase 2): the approvals,
// the denials remembered for a while, the paused connections waiting for an answer, their
// one-time tokens, and what an answer or the timeout does to them. The extension keeps one AskState behind a lock and turns the results
// into NetworkExtension calls; `Flow` is its paused flow, and a test's stand-in.
//
// Times are seconds on a monotonic clock (the system uptime in the extension), passed in by the
// caller, so nothing here reads a clock.

/// Which of an interpreter's scripts an event, an approval or a denial is about. An interpreter's
/// identity is every script it runs: one approval of uv's python3.14 to oauth2.googleapis.com for
/// mailctl would let any script of that python reach the host for the day. So the agent's answer
/// covers the script its event named, and only the owner, with Touch ID, answers for them all.
/// The script comes from the process's command line (ProcessArguments): any program can start an
/// interpreter with any script name, so a scope only narrows what an answer covers, and an
/// answer still never trusts the name.
public enum ScriptScope: Hashable, Sendable {
    /// Every connection of the app to the host: code that is no interpreter, or an owner's answer
    /// that names no script.
    case any
    /// An interpreter (Interpreters) running this script; nil when its command line names none
    /// (`python3 -c`, a REPL) or cannot be read.
    case script(String?)

    /// The scope of a connection from the executable at `executablePath`; `script` is read only
    /// for an interpreter.
    public static func of(executablePath: String?, script: () -> String?) -> ScriptScope {
        guard let executablePath, Interpreters.contains(path: executablePath) else { return .any }
        return .script(script())
    }

    /// The script, for an event or a summary; nil for `.any` and for an interpreter with none.
    public var script: String? {
        if case .script(let script) = self { return script }
        return nil
    }

    /// Whether a person's answer can name this script: a full path or `-m module`, as events show
    /// them when the process's folder is known, with no control characters.
    public static func canName(_ script: String) -> Bool {
        validPath(script) && (script.hasPrefix("/") || script.hasPrefix("-m "))
    }
}

/// One app and one host: what an approval and an answer name. Ports do not matter. For an
/// interpreter, also its script (ScriptScope).
public struct ApprovalKey: Hashable, Sendable {
    public let identity: AppIdentity
    /// A normalized host name, or an IP address (`normalizeDestination`). An address covers only
    /// connections to that address that have no name: a connection with a name is asked about,
    /// and approved, by its name.
    public let host: String
    public let scope: ScriptScope

    public init(identity: AppIdentity, host: String, scope: ScriptScope = .any) {
        self.identity = identity
        self.host = host
        self.scope = scope
    }
}

/// Approvals in memory, each with an expiry. The extension saves its approvals to a file and
/// reads them back when it starts (SavedApprovals), so they outlast an upgrade or a restart of the
/// Mac. AskState keeps its remembered denials in one too, never saved.
public struct ApprovalTable: Sendable {
    public static let maximumSeconds = 86_400
    public static let maximumEntries = 1024

    private var expiries: [ApprovalKey: TimeInterval] = [:]
    /// Goes up with each change, so the extension saves only a table that changed.
    public private(set) var revision = 0

    public init() {}

    public var count: Int { expiries.count }

    /// Adds an approval for `seconds`, cut to 1 s ... 24 h. An approval that already lasts longer
    /// keeps its expiry. When the table is full, the approval closest to expiring goes. Returns
    /// the expiry.
    @discardableResult
    public mutating func add(_ key: ApprovalKey, seconds: Int, now: TimeInterval) -> TimeInterval {
        let expires = now + TimeInterval(min(max(seconds, 1), Self.maximumSeconds))
        if expiries[key] == nil, expiries.count >= Self.maximumEntries {
            expire(now: now)
            if expiries.count >= Self.maximumEntries, let soonest = expiries.min(by: { $0.value < $1.value })?.key {
                expiries.removeValue(forKey: soonest)
            }
        }
        let kept = max(expiries[key] ?? 0, expires)
        expiries[key] = kept
        revision += 1
        return kept
    }

    public func covers(_ key: ApprovalKey, now: TimeInterval) -> Bool {
        guard let expires = expiries[key] else { return false }
        return expires > now
    }

    /// Whether a connection of this app to this host, from code of this scope, is covered: by an
    /// entry for any script, or by one for its own.
    public func covers(_ identity: AppIdentity, host: String, scope: ScriptScope, now: TimeInterval) -> Bool {
        covers(ApprovalKey(identity: identity, host: host), now: now)
            || (scope != .any && covers(ApprovalKey(identity: identity, host: host, scope: scope), now: now))
    }

    /// True when there was one.
    @discardableResult
    public mutating func remove(_ key: ApprovalKey) -> Bool {
        guard expiries.removeValue(forKey: key) != nil else { return false }
        revision += 1
        return true
    }

    /// Removes what an answer for `key` takes back: for one script, that entry; for any script,
    /// the app and host's entries of every scope. True when there was one.
    @discardableResult
    public mutating func removeCovered(by key: ApprovalKey) -> Bool {
        guard key.scope == .any else { return remove(key) }
        let before = expiries.count
        expiries = expiries.filter { $0.key.identity != key.identity || $0.key.host != key.host }
        guard expiries.count != before else { return false }
        revision += 1
        return true
    }

    public mutating func expire(now: TimeInterval) {
        let before = expiries.count
        expiries = expiries.filter { $0.value > now }
        if expiries.count != before { revision += 1 }
    }

    public mutating func removeAll() {
        guard !expiries.isEmpty else { return }
        expiries.removeAll()
        revision += 1
    }

    public func summaries(now: TimeInterval) -> [ApprovalSummary] {
        expiries.filter { $0.value > now }
            .map { ApprovalSummary(app: AppReference($0.key.identity), host: $0.key.host,
                                   secondsLeft: Int(($0.value - now).rounded(.up)), scope: $0.key.scope) }
            .sorted { ($0.host, $0.app.signingID ?? $0.app.cdhash ?? "", $0.script ?? "")
                < ($1.host, $1.app.signingID ?? $1.app.cdhash ?? "", $1.script ?? "") }
    }
}

/// The approvals the extension saves, with the time of day they were saved at, so they outlast
/// an upgrade or a restart of the Mac (decided on 10 November 2026). Each keeps what it had left:
/// restored, it loses the time of day gone by since, and a clock set back never lengthens it.
/// The file is root's, mode 0600, beside the identity cache; remembered denials are not saved.
public struct SavedApprovals: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// Seconds since 1970.
    public let savedAt: Double
    public let approvals: [ApprovalSummary]

    public init(savedAt: Double, approvals: [ApprovalSummary]) {
        version = Self.currentVersion
        self.savedAt = savedAt
        self.approvals = approvals
    }

    enum CodingKeys: String, CodingKey {
        case version
        case savedAt = "saved_at"
        case approvals
    }
}

extension ApprovalTable {
    /// The file's contents: the approvals left at `now` (monotonic seconds), saved at `timeOfDay`
    /// (seconds since 1970). One for a link-local address is left out: its host names an interface
    /// by its number, which may be another interface's after a restart.
    public func saved(now: TimeInterval, timeOfDay: Double) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let kept = summaries(now: now).filter { IPAddress.strict($0.host)?.isLinkLocal != true }
        return try? encoder.encode(SavedApprovals(savedAt: timeOfDay, approvals: kept))
    }

    /// Adds the approvals in a file `saved` wrote, each for what it had left less the time of day
    /// gone by since. Returns how many were added; nil for a file this version did not write, or
    /// one with an entry that is not valid, which adds nothing.
    @discardableResult
    public mutating func restore(_ data: Data, now: TimeInterval, timeOfDay: Double) -> Int? {
        guard let file = try? JSONDecoder().decode(SavedApprovals.self, from: data),
              file.version == SavedApprovals.currentVersion, file.savedAt.isFinite,
              file.approvals.count <= Self.maximumEntries,
              file.approvals.allSatisfy({ $0.isValid && $0.secondsLeft <= Self.maximumSeconds }) else { return nil }
        let gone = max(0, timeOfDay - file.savedAt)
        var added = 0
        for approval in file.approvals {
            guard let identity = approval.app.identity else { continue }
            let left = Double(approval.secondsLeft) - gone
            guard left >= 1 else { continue }
            add(ApprovalKey(identity: identity, host: approval.host, scope: approval.scope),
                seconds: Int(left), now: now)
            added += 1
        }
        return added
    }
}

/// Repeated connections with the same app, host and port share one event while it is pending;
/// an interpreter's, only those of the same script, so that an answer for one script releases no
/// other script's connections.
public struct PendingKey: Hashable, Sendable {
    public let identity: AppIdentity
    public let host: String
    public let port: UInt16
    public let scope: ScriptScope

    public init(identity: AppIdentity, host: String, port: UInt16, scope: ScriptScope = .any) {
        self.identity = identity
        self.host = host
        self.port = port
        self.scope = scope
    }

    public var approvalKey: ApprovalKey { ApprovalKey(identity: identity, host: host, scope: scope) }

    /// Whether an answer for `key` resolves this event: the same app and host, and the same
    /// script unless the answer is for any script.
    func answered(by key: ApprovalKey) -> Bool {
        identity == key.identity && host == key.host && (key.scope == .any || scope == key.scope)
    }
}

public struct PendingFlow<Flow> {
    public let flow: Flow
    /// False when the flow's address was not among the host's answers: an approval drops it.
    public let addressMatches: Bool
    /// Monotonic seconds when this flow is dropped although its event is still pending, for a
    /// connection the server will not keep waiting; nil to wait for the event's deadline.
    public let holdUntil: TimeInterval?
}

public struct PendingEntry<Flow> {
    public let event: HookEvent
    public let key: PendingKey
    /// Monotonic seconds; the flows are dropped then.
    public let deadline: TimeInterval
    public fileprivate(set) var flows: [PendingFlow<Flow>]
    /// Set by the first answer that presents the token, accepted or not.
    public fileprivate(set) var tokenSpent = false
}

/// What the extension's pending table holds at most. `PendingReply` takes its limits from here.
public enum AskLimits {
    public static let events = 256
    public static let flows = 1024
    public static let flowsPerEvent = 64
    /// A quarter of the events and of the flows. One app that connects to many hosts, or to one
    /// address on many ports, could otherwise fill the table, and every other app's connections
    /// were then dropped as `ask_capacity` with no event.
    public static let eventsPerApp = events / 4
    public static let flowsPerApp = flows / 4
}

/// The paused connections waiting for an answer, at most one event per app, host and port.
public struct PendingTable<Flow> {
    public let maximumEvents: Int
    public let maximumFlows: Int
    public let maximumFlowsPerEvent: Int
    public let maximumEventsPerApp: Int
    public let maximumFlowsPerApp: Int

    private var entries: [String: PendingEntry<Flow>] = [:]
    private var idsByKey: [PendingKey: String] = [:]
    public private(set) var flowCount = 0

    public init(maximumEvents: Int = AskLimits.events, maximumFlows: Int = AskLimits.flows,
                maximumFlowsPerEvent: Int = AskLimits.flowsPerEvent,
                maximumEventsPerApp: Int = AskLimits.eventsPerApp, maximumFlowsPerApp: Int = AskLimits.flowsPerApp) {
        self.maximumEvents = maximumEvents
        self.maximumFlows = maximumFlows
        self.maximumFlowsPerEvent = maximumFlowsPerEvent
        self.maximumEventsPerApp = maximumEventsPerApp
        self.maximumFlowsPerApp = maximumFlowsPerApp
    }

    public var eventCount: Int { entries.count }

    public func entry(_ id: String) -> PendingEntry<Flow>? { entries[id] }

    public enum Added: Equatable {
        /// A new event: send it to the daemon.
        case raised(HookEvent)
        /// The flow waits on the event already pending for its app, host and port.
        case joined(eventID: String)
        /// Too many paused flows or events, or no event could be made: drop the flow.
        case full
        /// The flow's app has its share of the paused flows or of the events: drop the flow.
        case appFull
    }

    /// Pauses `flow` under `key`. A new key gets a new event from `makeEvent`, which receives the
    /// deadline as seconds from now; the event ID must not collide with a pending one. With
    /// `holdFor`, the flow itself goes after that many seconds (`expireHolds`) and its event stays.
    public mutating func add(_ flow: Flow, key: PendingKey, addressMatches: Bool, now: TimeInterval,
                             timeout: TimeInterval, holdFor: TimeInterval? = nil,
                             makeEvent: (TimeInterval) throws -> HookEvent) -> Added {
        guard flowCount < maximumFlows else { return .full }
        let app = held(by: key.identity)
        guard app.flows < maximumFlowsPerApp else { return .appFull }
        let pendingFlow = PendingFlow(flow: flow, addressMatches: addressMatches, holdUntil: holdFor.map { now + $0 })
        if let id = idsByKey[key], var entry = entries[id] {
            guard entry.flows.count < maximumFlowsPerEvent else { return .full }
            entry.flows.append(pendingFlow)
            entries[id] = entry
            flowCount += 1
            return .joined(eventID: id)
        }
        guard entries.count < maximumEvents else { return .full }
        // An event with no flow left still counts: it stays until its deadline.
        guard app.events < maximumEventsPerApp else { return .appFull }
        for _ in 0..<3 {
            guard let event = try? makeEvent(timeout) else { return .full }
            guard entries[event.id] == nil else { continue }
            entries[event.id] = PendingEntry(event: event, key: key, deadline: now + timeout, flows: [pendingFlow])
            idsByKey[key] = event.id
            flowCount += 1
            return .raised(event)
        }
        return .full
    }

    /// The events pending for this app, and their flows.
    private func held(by identity: AppIdentity) -> (events: Int, flows: Int) {
        var held = (events: 0, flows: 0)
        for entry in entries.values where entry.key.identity == identity {
            held.events += 1
            held.flows += entry.flows.count
        }
        return held
    }

    /// Removes and returns the events whose deadline has passed.
    public mutating func expire(now: TimeInterval) -> [PendingEntry<Flow>] {
        remove { $0.deadline <= now }
    }

    /// Removes the flows whose hold has run out from the events still pending, and returns them
    /// with their event's ID. The events stay, token and all, possibly with no flow left: an
    /// answer still counts, and an approval covers the app's next connection.
    public mutating func expireHolds(now: TimeInterval) -> [(flow: Flow, eventID: String)] {
        var dropped: [(flow: Flow, eventID: String)] = []
        for id in entries.keys.sorted() {
            guard var entry = entries[id], entry.flows.contains(where: { ($0.holdUntil ?? .infinity) <= now }) else { continue }
            for paused in entry.flows where (paused.holdUntil ?? .infinity) <= now { dropped.append((paused.flow, id)) }
            entry.flows.removeAll { ($0.holdUntil ?? .infinity) <= now }
            entries[id] = entry
        }
        flowCount -= dropped.count
        return dropped
    }

    /// Removes and returns every event for this app and host, on any port; for one script, only
    /// that script's events.
    public mutating func resolve(_ key: ApprovalKey) -> [PendingEntry<Flow>] {
        remove { $0.key.answered(by: key) }
    }

    public mutating func removeAll() -> [PendingEntry<Flow>] {
        remove { _ in true }
    }

    private mutating func remove(where predicate: (PendingEntry<Flow>) -> Bool) -> [PendingEntry<Flow>] {
        let removed = entries.values.filter(predicate).sorted { $0.deadline < $1.deadline }
        for entry in removed {
            entries.removeValue(forKey: entry.event.id)
            idsByKey.removeValue(forKey: entry.key)
            flowCount -= entry.flows.count
        }
        return removed
    }

    public enum TokenCheck: Equatable {
        /// The token is this pending event's, and is now spent.
        case valid(eventID: String, key: PendingKey)
        /// No pending event has it: wrong, answered already, or timed out and removed.
        case unknown
        /// An earlier answer presented it.
        case spent
        /// Its event's deadline has passed.
        case expired
    }

    /// Finds the event this token belongs to and spends the token. Every pending token is
    /// compared, each in constant time, so the time taken does not tell which one matched or how
    /// much of it did.
    public mutating func spendToken(_ token: String, now: TimeInterval) -> TokenCheck {
        var found: String?
        for (id, entry) in entries where EventToken.matches(token, entry.event.token) && found == nil {
            found = id
        }
        guard let id = found, var entry = entries[id] else { return .unknown }
        guard !entry.tokenSpent else { return .spent }
        entry.tokenSpent = true
        entries[id] = entry
        guard entry.deadline > now else { return .expired }
        return .valid(eventID: id, key: entry.key)
    }

    /// What `blackice pending` shows: no tokens.
    public func summaries(now: TimeInterval) -> [PendingSummary] {
        entries.values.sorted { $0.deadline < $1.deadline }.map { entry in
            PendingSummary(id: entry.event.id, app: AppReference(entry.key.identity), path: entry.event.app.path,
                           host: entry.key.host, ip: entry.event.ip, port: entry.key.port,
                           secondsLeft: max(0, Int((entry.deadline - now).rounded(.up))), connections: entry.flows.count,
                           script: entry.event.app.script)
        }
    }
}

/// What to do with one paused flow.
public struct Release<Flow> {
    public let flow: Flow
    public let allow: Bool
    public let reason: String
    public let eventID: String
}

public struct AskState<Flow> {
    /// How long a deny keeps the app and host from being asked about again.
    public static var rememberedDenialSeconds: Int { 600 }

    public var approvals = ApprovalTable()
    /// The app and host pairs denied in the last `rememberedDenialSeconds`, kept the way approvals
    /// are: their new connections are dropped at once (`denied;remembered`), with no event and no
    /// hook. Only an answer adds one, never a timeout or a hook with no answer; an approval of the
    /// pair removes it, and a configuration change or a stop forgets them all (`endAll`).
    public var denials = ApprovalTable()
    public var pending: PendingTable<Flow>

    public init(pending: PendingTable<Flow> = PendingTable()) {
        self.pending = pending
    }

    public struct Outcome {
        public let reply: AnswerReply
        public let released: [Release<Flow>]
        public let verdicts: [(eventID: String, verdict: Verdict)]
    }

    /// Applies one checked `AnswerRequest`.
    ///
    /// With a token: the token must belong to a pending event that has not passed its deadline,
    /// and that event must name the same app and host as the request. The first answer that
    /// presents a token spends it, even when it is refused for naming another app or host.
    /// With touch_id: the signed CLI confirmed a person, and any app and host may be named, with
    /// or without a pending event.
    ///
    /// approve adds the approval, replaces a remembered denial, and releases the paused flows for
    /// that app and host on every port; a flow whose address did not match its host is dropped
    /// instead. deny drops them, removes an approval for that app and host, if there is one, and
    /// remembers the denial for `rememberedDenialSeconds`.
    ///
    /// An answer with a token covers the script its event named (ScriptScope), which only the
    /// extension knows; a person's covers the script the request names, or, with none, every one.
    public mutating func answer(_ request: AnswerRequest, now: TimeInterval) -> Outcome {
        guard let identity = request.identity, isNormalDestination(request.host) else {
            return refused("invalid_request", "the request does not name one app and one host")
        }
        var key = ApprovalKey(identity: identity, host: request.host, scope: request.scope)
        if request.authorization == .token {
            switch pending.spendToken(request.token ?? "", now: now) {
            case .unknown:
                return refused("token_unknown", "no pending connection has this token; it was answered or timed out")
            case .spent:
                return refused("token_spent", "this token was already used")
            case .expired:
                return refused("token_expired", "the connection's deadline has passed")
            case .valid(_, let eventKey):
                guard eventKey.identity == identity, eventKey.host == request.host else {
                    return refused("token_mismatch", "the token belongs to another app or host; it is now spent")
                }
                key = eventKey.approvalKey
            }
        }
        let entries: [PendingEntry<Flow>]
        var released: [Release<Flow>] = []
        let message: String
        switch request.kind {
        case .approve:
            let expires = approvals.add(key, seconds: request.seconds ?? 0, now: now)
            let replaced = denials.removeCovered(by: key)
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: paused.addressMatches,
                                            reason: paused.addressMatches ? "approved" : "approved;address_mismatch",
                                            eventID: entry.event.id))
                }
            }
            message = "Approved \(identity.name) → \(request.host)\(Self.describe(key.scope)) for \(Describe.left(Int((expires - now).rounded())))"
                + (replaced ? ", replacing its denial" : "")
        case .deny:
            let revoked = approvals.removeCovered(by: key)
            // A denial of every script takes the place of each script's, which ends no later.
            if key.scope == .any { denials.removeCovered(by: key) }
            let remembered = denials.add(key, seconds: Self.rememberedDenialSeconds, now: now)
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: false, reason: "denied", eventID: entry.event.id))
                }
            }
            message = "Denied \(identity.name) → \(request.host)\(Self.describe(key.scope)) for \(Describe.left(Int((remembered - now).rounded())))"
                + (revoked ? ", removing its approval" : "")
        }
        let verdict: Verdict = request.kind == .approve ? .approved : .denied
        let ids = entries.map(\.event.id)
        let allowed = released.filter(\.allow).count
        let waiting = Describe.count(released.count, "waiting connection")
        let detail = released.isEmpty ? "; nothing was waiting"
            : request.kind == .deny ? "; \(waiting) dropped"
            : allowed == released.count ? "; \(waiting) let through"
            : "; \(waiting), \(allowed) let through (the others went to another address)"
        return Outcome(reply: AnswerReply(status: .done, reason: verdict.rawValue, message: message + detail,
                                          events: ids, released: released.count),
                       released: released, verdicts: ids.map { ($0, verdict) })
    }

    /// Drops the flows of events past their deadline, then the flows whose hold ran out while
    /// their event stays pending (`hold_expired`), and forgets expired approvals and denials. An
    /// event that times out is not remembered as a denial. `timedOut` lists only the events that
    /// ended.
    public mutating func expire(now: TimeInterval) -> (released: [Release<Flow>], timedOut: [String]) {
        approvals.expire(now: now)
        denials.expire(now: now)
        let entries = pending.expire(now: now)
        var released = entries.flatMap { entry in
            entry.flows.map { Release(flow: $0.flow, allow: false, reason: "timeout", eventID: entry.event.id) }
        }
        released += pending.expireHolds(now: now).map {
            Release(flow: $0.flow, allow: false, reason: "hold_expired", eventID: $0.eventID)
        }
        return (released, entries.map(\.event.id))
    }

    /// `blackice deny --all`: forgets every approval and returns how many still counted. What
    /// waits keeps waiting, and the remembered denials stay.
    public mutating func forgetApprovals(now: TimeInterval) -> Int {
        approvals.expire(now: now)
        let count = approvals.count
        approvals.removeAll()
        return count
    }

    /// A configuration change or a stop: removes and returns every pending event, and forgets
    /// the denials, which belong to the configuration they were given under. Approvals stay.
    public mutating func endAll() -> [PendingEntry<Flow>] {
        denials.removeAll()
        return pending.removeAll()
    }

    /// ", running /path" for one script's answer, ", with no script" for an interpreter that names
    /// none, nothing for every script. Escaped: the name comes from the process.
    static func describe(_ scope: ScriptScope) -> String {
        switch scope {
        case .any: return ""
        // The reply's message is at most 1024 bytes: a long path keeps its start and its file name.
        case .script(let script?): return " (running \(Describe.script(script)))"
        case .script(nil): return " (with no script)"
        }
    }

    private func refused(_ reason: String, _ message: String) -> Outcome {
        Outcome(reply: AnswerReply(status: .refused, reason: reason, message: message), released: [], verdicts: [])
    }
}
