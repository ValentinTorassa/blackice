import Foundation
import Testing
@testable import BlackiceCore

// An app in a loop of dropped connections: its next ones wait for their drop. Integers stand in
// for paused flows, and the clock is passed in by hand.

struct RepeatedDropsTests {
    private typealias Drops = RepeatedDrops<Int>
    private let app = "apple/com.apple.identityservicesd"

    /// Drops `count` connections of `app` at `now` and returns the decisions.
    private func drop(_ drops: inout Drops, _ count: Int, app: String, now: TimeInterval, from first: Int = 0) -> [Drops.Decision] {
        (0..<count).map { drops.add(first + $0, app: app, now: now) }
    }

    @Test func aFewDropsAreDroppedAtOnce() {
        var drops = Drops()
        // The threshold, every 2 s, for a minute: never more than it within one window.
        for round in 0..<30 {
            let decisions = drop(&drops, Drops.threshold, app: app, now: TimeInterval(round) * Drops.window)
            #expect(decisions.allSatisfy { $0 == .dropNow })
        }
        #expect(!drops.isDelaying(app) && drops.waitingCount == 0 && drops.unlogged == 0)
    }

    @Test func aLoopOfDropsIsDelayedAndThenComesOncePerDelay() {
        var drops = Drops()
        let burst = drop(&drops, Drops.threshold + 20, app: app, now: 100)
        #expect(burst.prefix(Drops.threshold).allSatisfy { $0 == .dropNow })
        // Its share waits; the rest of the burst is dropped with no log line.
        #expect(burst.dropFirst(Drops.threshold).prefix(drops.limitPerApp).allSatisfy { $0 == .delayed })
        #expect(burst.suffix(20 - drops.limitPerApp).allSatisfy { $0 == .dropUnlogged })
        #expect(drops.waitingCount == drops.limitPerApp)
        #expect(drops.takeUnlogged() == 20 - drops.limitPerApp && drops.takeUnlogged() == 0)

        // Nothing is due before the delay, and all of it after.
        #expect(drops.due(now: 100 + Drops.delay - 0.1).isEmpty)
        let overdue = drops.due(now: 100 + Drops.delay)
        #expect(overdue == Array(Drops.threshold..<Drops.threshold + drops.limitPerApp))
        #expect(drops.waitingCount == 0)

        // A program that tries again after each failure now waits each time, for as long as it goes on.
        var now = 100 + Drops.delay
        for attempt in 0..<20 {
            let decision = drops.add(1000 + attempt, app: app, now: now)
            #expect(decision == .delayed)
            now += Drops.delay
            #expect(drops.due(now: now) == [1000 + attempt])
        }
    }

    @Test func aQuietAppIsDroppedAtOnceAgain() {
        var drops = Drops()
        _ = drop(&drops, Drops.threshold + 1, app: app, now: 0)
        #expect(drops.isDelaying(app))
        #expect(drops.due(now: Drops.delay) == [Drops.threshold])
        // Still delayed just before the quiet time is up, counted from its last drop.
        let before = drops.add(1, app: app, now: Drops.quiet - 0.1)
        #expect(before == .delayed)
        #expect(drops.due(now: Drops.quiet + Drops.delay) == [1])
        let after = drops.add(2, app: app, now: 2 * Drops.quiet)
        #expect(after == .dropNow && !drops.isDelaying(app))
    }

    @Test func oneAppsLoopDelaysNoOtherApp() {
        var drops = Drops()
        _ = drop(&drops, Drops.threshold + 100, app: app, now: 0)
        let other = drop(&drops, Drops.threshold, app: "apple/com.apple.curl", now: 0.5)
        #expect(other.allSatisfy { $0 == .dropNow })
        #expect(!drops.isDelaying("apple/com.apple.curl"))
    }

    @Test func delayedConnectionsAreBoundedForEveryAppTogether() {
        var drops = Drops(limit: 10, limitPerApp: 8)
        _ = drop(&drops, Drops.threshold + 8, app: "a", now: 0)
        let second = drop(&drops, Drops.threshold + 8, app: "b", now: 0)
        #expect(drops.waitingCount == 10)
        #expect(second.filter { $0 == .delayed }.count == 2 && second.filter { $0 == .dropUnlogged }.count == 6)
    }

    @Test func removeAllReturnsTheDelayedAndForgetsTheCounts() {
        var drops = Drops()
        _ = drop(&drops, Drops.threshold + 3, app: app, now: 0)
        #expect(drops.removeAll() == Array(Drops.threshold..<Drops.threshold + 3))
        #expect(drops.waitingCount == 0 && !drops.isDelaying(app) && drops.due(now: 100).isEmpty)
        let next = drops.add(1, app: app, now: 0.5)
        #expect(next == .dropNow)
    }

    @Test func aFullTableOfAppsStillDroppingLeavesANewAppUncounted() {
        var drops = Drops()
        for index in 0..<Drops.maximumApps {
            let decision = drops.add(index, app: "app\(index)", now: 0)
            #expect(decision == .dropNow)
        }
        // Not counted: dropped at once however often it comes.
        let uncounted = drop(&drops, Drops.threshold + 5, app: "new", now: 1)
        #expect(uncounted.allSatisfy { $0 == .dropNow } && !drops.isDelaying("new"))
        // Once the others have been quiet, there is room again.
        let later = drop(&drops, Drops.threshold + 1, app: "new", now: 1 + Drops.quiet)
        #expect(later.last == .delayed)
    }
}
