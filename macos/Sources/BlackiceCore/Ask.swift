import Foundation

// Ask mode's state inside the extension, as plain values with tests (phase 2): the approvals,
// the denials remembered for a while, the paused connections waiting for an answer, their
// one-time tokens, and what an answer or the timeout does to them. The extension keeps one AskState behind a lock and turns the results
// into NetworkExtension calls; `Flow` is its paused flow, and a test's stand-in.
//
// Times are seconds on a monotonic clock (the system uptime in the extension), passed in by the
// caller, so nothing here reads a clock.

/// One app and one host: what an approval and an answer name. Ports do not matter.
public struct ApprovalKey: Hashable, Sendable {
    public let identity: AppIdentity
    /// A normalized host name, or an IP address (`normalizeDestination`). An address covers only
    /// connections to that address that have no name: a connection with a name is asked about,
    /// and approved, by its name.
    public let host: String

    public init(identity: AppIdentity, host: String) {
        self.identity = identity
        self.host = host
    }
}

/// Approvals in memory, each with an expiry. Gone when the extension stops. AskState keeps its
/// remembered denials in one too.
public struct ApprovalTable: Sendable {
    public static let maximumSeconds = 86_400
    public static let maximumEntries = 1024

    private var expiries: [ApprovalKey: TimeInterval] = [:]

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
        return kept
    }

    public func covers(_ key: ApprovalKey, now: TimeInterval) -> Bool {
        guard let expires = expiries[key] else { return false }
        return expires > now
    }

    /// True when there was one.
    @discardableResult
    public mutating func remove(_ key: ApprovalKey) -> Bool {
        expiries.removeValue(forKey: key) != nil
    }

    public mutating func expire(now: TimeInterval) {
        expiries = expiries.filter { $0.value > now }
    }

    public mutating func removeAll() { expiries.removeAll() }

    public func summaries(now: TimeInterval) -> [ApprovalSummary] {
        expiries.filter { $0.value > now }
            .map { ApprovalSummary(app: AppReference($0.key.identity), host: $0.key.host,
                                   secondsLeft: Int(($0.value - now).rounded(.up))) }
            .sorted { ($0.host, $0.app.signingID ?? $0.app.cdhash ?? "") < ($1.host, $1.app.signingID ?? $1.app.cdhash ?? "") }
    }
}

/// Repeated connections with the same app, host and port share one event while it is pending.
public struct PendingKey: Hashable, Sendable {
    public let identity: AppIdentity
    public let host: String
    public let port: UInt16

    public init(identity: AppIdentity, host: String, port: UInt16) {
        self.identity = identity
        self.host = host
        self.port = port
    }

    public var approvalKey: ApprovalKey { ApprovalKey(identity: identity, host: host) }
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
}

/// The paused connections waiting for an answer, at most one event per app, host and port.
public struct PendingTable<Flow> {
    public let maximumEvents: Int
    public let maximumFlows: Int
    public let maximumFlowsPerEvent: Int

    private var entries: [String: PendingEntry<Flow>] = [:]
    private var idsByKey: [PendingKey: String] = [:]
    public private(set) var flowCount = 0

    public init(maximumEvents: Int = AskLimits.events, maximumFlows: Int = AskLimits.flows,
                maximumFlowsPerEvent: Int = AskLimits.flowsPerEvent) {
        self.maximumEvents = maximumEvents
        self.maximumFlows = maximumFlows
        self.maximumFlowsPerEvent = maximumFlowsPerEvent
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
    }

    /// Pauses `flow` under `key`. A new key gets a new event from `makeEvent`, which receives the
    /// deadline as seconds from now; the event ID must not collide with a pending one. With
    /// `holdFor`, the flow itself goes after that many seconds (`expireHolds`) and its event stays.
    public mutating func add(_ flow: Flow, key: PendingKey, addressMatches: Bool, now: TimeInterval,
                             timeout: TimeInterval, holdFor: TimeInterval? = nil,
                             makeEvent: (TimeInterval) throws -> HookEvent) -> Added {
        guard flowCount < maximumFlows else { return .full }
        let pendingFlow = PendingFlow(flow: flow, addressMatches: addressMatches, holdUntil: holdFor.map { now + $0 })
        if let id = idsByKey[key], var entry = entries[id] {
            guard entry.flows.count < maximumFlowsPerEvent else { return .full }
            entry.flows.append(pendingFlow)
            entries[id] = entry
            flowCount += 1
            return .joined(eventID: id)
        }
        guard entries.count < maximumEvents else { return .full }
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

    /// Removes and returns every event for this app and host, on any port.
    public mutating func resolve(_ key: ApprovalKey) -> [PendingEntry<Flow>] {
        remove { $0.key.approvalKey == key }
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
                           secondsLeft: max(0, Int((entry.deadline - now).rounded(.up))), connections: entry.flows.count)
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
    public mutating func answer(_ request: AnswerRequest, now: TimeInterval) -> Outcome {
        guard let identity = request.identity, isNormalDestination(request.host) else {
            return refused("invalid_request", "the request does not name one app and one host")
        }
        let key = ApprovalKey(identity: identity, host: request.host)
        if request.authorization == .token {
            switch pending.spendToken(request.token ?? "", now: now) {
            case .unknown:
                return refused("token_unknown", "no pending connection has this token; it was answered or timed out")
            case .spent:
                return refused("token_spent", "this token was already used")
            case .expired:
                return refused("token_expired", "the connection's deadline has passed")
            case .valid(_, let eventKey):
                guard eventKey.approvalKey == key else {
                    return refused("token_mismatch", "the token belongs to another app or host; it is now spent")
                }
            }
        }
        let entries: [PendingEntry<Flow>]
        var released: [Release<Flow>] = []
        let message: String
        switch request.kind {
        case .approve:
            let expires = approvals.add(key, seconds: request.seconds ?? 0, now: now)
            let replaced = denials.remove(key)
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: paused.addressMatches,
                                            reason: paused.addressMatches ? "approved" : "approved;address_mismatch",
                                            eventID: entry.event.id))
                }
            }
            message = "approved \(identity.label) -> \(request.host) for \(Int((expires - now).rounded())) s"
                + (replaced ? "; its denial was removed" : "")
        case .deny:
            let revoked = approvals.remove(key)
            let remembered = denials.add(key, seconds: Self.rememberedDenialSeconds, now: now)
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: false, reason: "denied", eventID: entry.event.id))
                }
            }
            message = "denied \(identity.label) -> \(request.host) for \(Int((remembered - now).rounded())) s"
                + (revoked ? "; its approval was removed" : "")
        }
        let verdict: Verdict = request.kind == .approve ? .approved : .denied
        let ids = entries.map(\.event.id)
        let allowed = released.filter(\.allow).count
        let detail = released.isEmpty ? "; no connection was waiting"
            : "; \(released.count) waiting connection\(released.count == 1 ? "" : "s"), \(allowed) allowed"
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

    /// A configuration change or a stop: removes and returns every pending event, and forgets
    /// the denials, which belong to the configuration they were given under. Approvals stay.
    public mutating func endAll() -> [PendingEntry<Flow>] {
        denials.removeAll()
        return pending.removeAll()
    }

    private func refused(_ reason: String, _ message: String) -> Outcome {
        Outcome(reply: AnswerReply(status: .refused, reason: reason, message: message), released: [], verdicts: [])
    }
}
