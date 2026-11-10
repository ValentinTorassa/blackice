import Foundation

// An app whose dropped connection fails at once may open the next one at once. On 10 November
// 2026, after a restart, identityservicesd did that to a link-local peer about 430 times a second:
// the filter used half a core, new connections waited behind them, and the system log dropped most
// of the filter's lines. So once an app has had `threshold` connections dropped within `window`
// seconds, its next ones that would be dropped wait `delay` seconds first. A program that tries
// again after each failure then tries once per `delay`. Nothing passes that would not have: each
// delayed connection is dropped all the same.
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
    /// Apps counted at once. With the table full of apps still dropping, a new app is not counted
    /// and its connections are dropped at once, as before.
    public static var maximumApps: Int { 256 }

    /// Delayed connections at once, and one app's share of them.
    public let limit: Int
    public let limitPerApp: Int

    private struct App {
        var windowStart: TimeInterval
        var count = 0
        var lastDrop: TimeInterval
        var delaying = false
        var waiting = 0
    }

    private var apps: [String: App] = [:]
    private var waiting: [(flow: Flow, app: String, until: TimeInterval)] = []
    /// Connections dropped at once with no log line since `takeUnlogged`.
    public private(set) var unlogged = 0

    public init(limit: Int = 64, limitPerApp: Int = 8) {
        self.limit = limit
        self.limitPerApp = limitPerApp
    }

    public var waitingCount: Int { waiting.count }

    public enum Decision: Equatable {
        /// Drop it now and log it, as ever.
        case dropNow
        /// Kept here: pause it. `due` returns it when its delay is over, to be dropped then.
        case delayed
        /// The app is being delayed and has its share waiting: drop it now, with no log line.
        case dropUnlogged
    }

    /// A connection of `app` that the policy drops. `app` is its identity's label.
    public mutating func add(_ flow: Flow, app key: String, now: TimeInterval) -> Decision {
        if apps[key] == nil {
            if apps.count >= Self.maximumApps { forgetQuietApps(now: now) }
            guard apps.count < Self.maximumApps else { return .dropNow }
        }
        var app = apps[key] ?? App(windowStart: now, lastDrop: now)
        if app.delaying, app.waiting == 0, now - app.lastDrop >= Self.quiet {
            app = App(windowStart: now, lastDrop: now)
        }
        if now - app.windowStart >= Self.window {
            app.windowStart = now
            app.count = 0
        }
        app.count += 1
        app.lastDrop = now
        if app.count > Self.threshold { app.delaying = true }
        defer { apps[key] = app }
        guard app.delaying else { return .dropNow }
        guard waiting.count < limit, app.waiting < limitPerApp else {
            unlogged += 1
            return .dropUnlogged
        }
        app.waiting += 1
        waiting.append((flow, key, now + Self.delay))
        return .delayed
    }

    /// Removes and returns the connections whose delay is over.
    public mutating func due(now: TimeInterval) -> [Flow] {
        guard waiting.contains(where: { $0.until <= now }) else { return [] }
        var flows: [Flow] = []
        var left: [(flow: Flow, app: String, until: TimeInterval)] = []
        for entry in waiting {
            guard entry.until <= now else { left.append(entry); continue }
            flows.append(entry.flow)
            if let count = apps[entry.app]?.waiting { apps[entry.app]?.waiting = max(0, count - 1) }
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

    /// Whether `app`'s dropped connections are being delayed.
    public func isDelaying(_ app: String) -> Bool { apps[app]?.delaying == true }

    private mutating func forgetQuietApps(now: TimeInterval) {
        apps = apps.filter { $0.value.waiting > 0 || now - $0.value.lastDrop < Self.quiet }
    }
}
