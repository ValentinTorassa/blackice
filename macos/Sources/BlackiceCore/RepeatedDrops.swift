import Foundation

// An app whose dropped connection fails at once may open the next one at once. On 10 November
// 2026, after a restart, identityservicesd did that to a link-local peer about 430 times a second:
// the filter used half a core, new connections waited behind them, and the system log dropped most
// of the filter's lines. So once an app has had `threshold` connections dropped within `window`
// seconds, its next TCP connections that would be dropped wait `delay` seconds first. A program
// that tries again after each failure then tries once per `delay`. Nothing passes that would not
// have: each delayed connection is dropped all the same.
//
// Only TCP waits. A program does not wait for the drop of a UDP flow: on build 39, which delayed
// those too, sendto() returned at once and close() then took 1.00 s, the time macOS gives a socket
// whose flow is still paused. Past the threshold an app's UDP drops are dropped at once as ever,
// with `loggedPerWindow` log lines per `window` and the rest counted.
//
// The filter spends about 0.9 ms of processor time on a flow whatever it decides (12 programs at
// once, 560 flows a second, half a core, with no log line for most), so a loop with more
// connections at once than `limitPerApp` still costs that: the ones over the share cannot wait.
//
// Times are monotonic seconds passed in by the caller. `Flow` is the extension's paused flow, and
// a test's stand-in.

public struct RepeatedDrops<Flow> {
    /// Drops within `window` that start the delay for an app.
    public static var threshold: Int { 64 }
    public static var window: TimeInterval { 2 }
    /// How long a delayed connection waits for its drop.
    public static var delay: TimeInterval { 2 }
    /// With no dropped connection from the app for this long, its next ones are dropped at once again.
    public static var quiet: TimeInterval { 10 }
    /// An app is delayed for this long at a time, then counted afresh: a loop that goes on is
    /// delayed again after `threshold` more drops, and an app that had one burst and now has a
    /// connection dropped every few seconds stops waiting for each.
    public static var period: TimeInterval { 30 }
    /// Log lines per `window` for drops that do not wait, from an app past the threshold.
    public static var loggedPerWindow: Int { 8 }
    /// Apps counted at once, with those that wait and those that do not counted apart. With the
    /// table full of apps still dropping, a new app is not counted and its connections are dropped
    /// at once, as before.
    public static var maximumApps: Int { 256 }

    /// Delayed connections at once, and one app's share of them.
    public let limit: Int
    public let limitPerApp: Int

    private struct Key: Hashable {
        let app: String
        let waits: Bool
    }

    private struct App {
        var windowStart: TimeInterval
        var count = 0
        var lastDrop: TimeInterval
        /// When the app went past the threshold; nil while its drops are counted only.
        var delayingSince: TimeInterval?
        var waiting = 0
    }

    private var apps: [Key: App] = [:]
    private var waiting: [(flow: Flow, key: Key, until: TimeInterval)] = []
    /// Connections dropped at once with no log line since `takeUnlogged`.
    public private(set) var unlogged = 0

    public init(limit: Int = 256, limitPerApp: Int = 64) {
        self.limit = limit
        self.limitPerApp = limitPerApp
    }

    public var waitingCount: Int { waiting.count }

    public enum Decision: Equatable {
        /// Drop it now and log it, as ever.
        case dropNow
        /// Kept here: pause it. `due` returns it when its delay is over, to be dropped then.
        case delayed
        /// The app is past the threshold and this one cannot wait, or the app has its share
        /// waiting: drop it now, with no log line.
        case dropUnlogged
    }

    /// A connection of `app` that the policy drops. `app` is its identity's label. `waits` says
    /// whether the program waits for the verdict before it can try again: true for TCP.
    public mutating func add(_ flow: Flow, app: String, waits: Bool, now: TimeInterval) -> Decision {
        let key = Key(app: app, waits: waits)
        if apps[key] == nil {
            if apps.count >= Self.maximumApps { forgetQuietApps(now: now) }
            guard apps.count < Self.maximumApps else { return .dropNow }
        }
        var entry = apps[key] ?? App(windowStart: now, lastDrop: now)
        if let since = entry.delayingSince, now - entry.lastDrop >= Self.quiet || now - since >= Self.period {
            // Counted afresh. The ones still waiting keep their place in the share.
            entry = App(windowStart: now, lastDrop: now, waiting: entry.waiting)
        }
        if now - entry.windowStart >= Self.window {
            entry.windowStart = now
            entry.count = 0
        }
        entry.count += 1
        entry.lastDrop = now
        if entry.count > Self.threshold, entry.delayingSince == nil { entry.delayingSince = now }
        defer { apps[key] = entry }
        guard entry.delayingSince != nil else { return .dropNow }
        guard waits else {
            if entry.count <= Self.loggedPerWindow { return .dropNow }
            unlogged += 1
            return .dropUnlogged
        }
        guard waiting.count < limit, entry.waiting < limitPerApp else {
            unlogged += 1
            return .dropUnlogged
        }
        entry.waiting += 1
        waiting.append((flow, key, now + Self.delay))
        return .delayed
    }

    /// Removes and returns the connections whose delay is over.
    public mutating func due(now: TimeInterval) -> [Flow] {
        guard waiting.contains(where: { $0.until <= now }) else { return [] }
        var flows: [Flow] = []
        var left: [(flow: Flow, key: Key, until: TimeInterval)] = []
        for entry in waiting {
            guard entry.until <= now else { left.append(entry); continue }
            flows.append(entry.flow)
            if let count = apps[entry.key]?.waiting { apps[entry.key]?.waiting = max(0, count - 1) }
        }
        waiting = left
        return flows
    }

    /// How many connections were dropped with no log line since the last call.
    public mutating func takeUnlogged() -> Int {
        defer { unlogged = 0 }
        return unlogged
    }

    /// A configuration change or a stop: returns every delayed connection and forgets the counts.
    public mutating func removeAll() -> [Flow] {
        let flows = waiting.map(\.flow)
        waiting.removeAll()
        apps.removeAll()
        return flows
    }

    /// Whether `app` is past the threshold: its dropped connections wait, or with `waits` false
    /// most of them go unlogged.
    public func isDelaying(_ app: String, waits: Bool = true) -> Bool {
        apps[Key(app: app, waits: waits)]?.delayingSince != nil
    }

    private mutating func forgetQuietApps(now: TimeInterval) {
        apps = apps.filter { $0.value.waiting > 0 || now - $0.value.lastDrop < Self.quiet }
    }
}
