import Foundation

// Ask mode's state inside the extension, as plain values with tests (phase 2): the approvals,
// the paused connections waiting for an answer, their one-time tokens, and what an answer or the
// timeout does to them. The extension keeps one AskState behind a lock and turns the results
// into NetworkExtension calls; `Flow` is its paused flow, and a test's stand-in.
//
// Times are seconds on a monotonic clock (the system uptime in the extension), passed in by the
// caller, so nothing here reads a clock.

/// One app and one host: what an approval and an answer name. Ports do not matter.
public struct ApprovalKey: Hashable, Sendable {
    public let identity: AppIdentity
    /// Normalized.
    public let host: String

    public init(identity: AppIdentity, host: String) {
        self.identity = identity
        self.host = host
    }
}

/// Approvals in memory, each with an expiry. Gone when the extension stops.
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

/// The paused connections waiting for an answer, at most one event per app, host and port.
public struct PendingTable<Flow> {
    public let maximumEvents: Int
    public let maximumFlows: Int
    public let maximumFlowsPerEvent: Int

    private var entries: [String: PendingEntry<Flow>] = [:]
    private var idsByKey: [PendingKey: String] = [:]
    public private(set) var flowCount = 0

    public init(maximumEvents: Int = 256, maximumFlows: Int = 1024, maximumFlowsPerEvent: Int = 64) {
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
    /// deadline as seconds from now; the event ID must not collide with a pending one.
    public mutating func add(_ flow: Flow, key: PendingKey, addressMatches: Bool, now: TimeInterval,
                             timeout: TimeInterval, makeEvent: (TimeInterval) throws -> HookEvent) -> Added {
        guard flowCount < maximumFlows else { return .full }
        if let id = idsByKey[key], var entry = entries[id] {
            guard entry.flows.count < maximumFlowsPerEvent else { return .full }
            entry.flows.append(PendingFlow(flow: flow, addressMatches: addressMatches))
            entries[id] = entry
            flowCount += 1
            return .joined(eventID: id)
        }
        guard entries.count < maximumEvents else { return .full }
        for _ in 0..<3 {
            guard let event = try? makeEvent(timeout) else { return .full }
            guard entries[event.id] == nil else { continue }
            entries[event.id] = PendingEntry(event: event, key: key, deadline: now + timeout,
                                             flows: [PendingFlow(flow: flow, addressMatches: addressMatches)])
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
    public var approvals = ApprovalTable()
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
    /// approve adds the approval and releases the paused flows for that app and host on every
    /// port; a flow whose address did not match its host is dropped instead. deny drops them and
    /// removes an approval for that app and host, if there is one.
    public mutating func answer(_ request: AnswerRequest, now: TimeInterval) -> Outcome {
        guard let identity = request.identity, normalizeHost(request.host) == request.host else {
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
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: paused.addressMatches,
                                            reason: paused.addressMatches ? "approved" : "approved;address_mismatch",
                                            eventID: entry.event.id))
                }
            }
            message = "approved \(identity.label) -> \(request.host) for \(Int((expires - now).rounded())) s"
        case .deny:
            let revoked = approvals.remove(key)
            entries = pending.resolve(key)
            for entry in entries {
                for paused in entry.flows {
                    released.append(Release(flow: paused.flow, allow: false, reason: "denied", eventID: entry.event.id))
                }
            }
            message = "denied \(identity.label) -> \(request.host)" + (revoked ? "; its approval was removed" : "")
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

    /// Drops the flows of events past their deadline and forgets expired approvals.
    public mutating func expire(now: TimeInterval) -> (released: [Release<Flow>], timedOut: [String]) {
        approvals.expire(now: now)
        let entries = pending.expire(now: now)
        let released = entries.flatMap { entry in
            entry.flows.map { Release(flow: $0.flow, allow: false, reason: "timeout", eventID: entry.event.id) }
        }
        return (released, entries.map(\.event.id))
    }

    private func refused(_ reason: String, _ message: String) -> Outcome {
        Outcome(reply: AnswerReply(status: .refused, reason: reason, message: message), released: [], verdicts: [])
    }
}
