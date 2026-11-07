import Foundation

/// How long a flow held for its TLS ClientHello may take, and what its drop is called when it
/// runs out. An app can open a connection and write nothing for a while: the spare of two opened at
/// once, or one kept ready for the next request. On 5 November 2026 fx and Claude Code (both Bun)
/// lost 175 connections in two days to a deadline of 10 s from the connect. So a flow may stay quiet
/// for `quietSeconds` before its first byte, and has `helloSeconds` from that byte for the whole
/// hello. No byte passes before a verdict either way, so the longer wait lets nothing through.
public struct HelloDeadline: Equatable, Sendable {
    /// Before the first byte.
    public static let quietSeconds: TimeInterval = 120
    /// From the first byte to a whole hello.
    public static let helloSeconds: TimeInterval = 10

    /// When the flow is dropped if it has not been decided.
    public private(set) var at: TimeInterval
    /// Whether a byte has come in.
    public private(set) var started = false

    public init(heldAt now: TimeInterval) {
        at = now + Self.quietSeconds
    }

    /// Called with each outbound callback, before `passed(now:)`: the first one starts the hello's
    /// own time, so a first byte late in the quiet time still gets all of `helloSeconds`.
    public mutating func bytesArrived(now: TimeInterval) {
        guard !started, now < at else { return }
        started = true
        at = now + Self.helloSeconds
    }

    public func passed(now: TimeInterval) -> Bool { now >= at }

    /// The reason a flow dropped at this deadline is logged with.
    public var reason: String { started ? "server_name_timeout" : "idle_before_hello" }
}

/// One flow held for its ClientHello, as `HoldPool.admit` sees it.
public struct HeldPlace<ID: Hashable> {
    public let id: ID
    /// The flow's app (`IdentityResolution.appIdentity`).
    public let app: AppIdentity?
    public let deadline: HelloDeadline

    public init(id: ID, app: AppIdentity?, deadline: HelloDeadline) {
        self.id = id
        self.app = app
        self.deadline = deadline
    }
}

/// Room for the flows held for their ClientHello: at most `capacity` at once, and `share` of them
/// from one app. With no share per app, one app could keep the pool full with connections that
/// write nothing (an ad hoc program too), and every other app's new TLS connections were dropped
/// as `hold_capacity`. Refusing an app's new flow at its share would not
/// do either: a socket closed with no callback leaves its entry quiet for all of `quietSeconds`
/// (Claude Code kept about 70 such entries at once on 6 November 2026), and its real connections
/// would be dropped behind them. So a new flow takes the place of the oldest quiet flow, one that
/// has sent no byte: its own app's at its share, or, when the pool is full, one of the app that
/// holds the most. A flow whose hello has started keeps its place.
public enum HoldPool {
    public static let capacity = 256
    /// A quarter of the pool.
    public static let share = 64

    public enum Admission<ID: Hashable>: Equatable {
        /// Hold the new flow, after dropping `evicting` as `evicted_quiet` when there is one.
        case hold(evicting: ID?)
        /// Drop the new flow with this reason: `hold_capacity_app` when its app holds its share
        /// and none of those is quiet, `hold_capacity` when the pool is full and none is quiet.
        case refuse(String)
    }

    /// Where a new flow of `app` goes, with `held` the flows held now.
    public static func admit<ID: Hashable>(_ app: AppIdentity?, held: some Collection<HeldPlace<ID>>,
                                           capacity: Int = HoldPool.capacity,
                                           share: Int = HoldPool.share) -> Admission<ID> {
        var counts: [AppIdentity?: Int] = [:]
        for place in held { counts[place.app, default: 0] += 1 }
        // A quiet flow's deadline is its hold time plus `quietSeconds`: the earliest is the oldest.
        let quiet = held.filter { !$0.deadline.started }
        if counts[app, default: 0] >= share {
            guard let oldest = quiet.filter({ $0.app == app }).min(by: { $0.deadline.at < $1.deadline.at }) else {
                return .refuse("hold_capacity_app")
            }
            return .hold(evicting: oldest.id)
        }
        guard held.count >= capacity else { return .hold(evicting: nil) }
        // Of the apps with a quiet flow, the one that holds the most gives up its oldest.
        let largest = quiet.max { a, b in
            let (countA, countB) = (counts[a.app, default: 0], counts[b.app, default: 0])
            return countA != countB ? countA < countB : a.deadline.at > b.deadline.at
        }
        guard let largest else { return .refuse("hold_capacity") }
        return .hold(evicting: largest.id)
    }
}
