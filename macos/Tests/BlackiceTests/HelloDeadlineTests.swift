import Foundation
import Testing
@testable import BlackiceCore

@Suite struct HelloDeadlineTests {
    @Test func aQuietFlowWaitsTwoMinutes() {
        let deadline = HelloDeadline(heldAt: 1000)
        #expect(!deadline.passed(now: 1010))
        #expect(!deadline.passed(now: 1119.9))
        #expect(deadline.passed(now: 1120))
        #expect(deadline.reason == "idle_before_hello")
    }

    @Test func theFirstByteGivesTheHelloTenSeconds() {
        var deadline = HelloDeadline(heldAt: 1000)
        deadline.bytesArrived(now: 1005)
        #expect(deadline.at == 1015)
        #expect(!deadline.passed(now: 1014.9))
        #expect(deadline.passed(now: 1015))
        #expect(deadline.reason == "server_name_timeout")
        // Later bytes keep the time the first one started.
        deadline.bytesArrived(now: 1012)
        #expect(deadline.at == 1015)
    }

    @Test func aFirstByteLateInTheQuietTimeStillGetsTenSeconds() {
        var deadline = HelloDeadline(heldAt: 1000)
        deadline.bytesArrived(now: 1119)
        #expect(deadline.at == 1129)
        #expect(!deadline.passed(now: 1125))
    }

    @Test func aByteAfterTheDeadlineChangesNothing() {
        var deadline = HelloDeadline(heldAt: 1000)
        deadline.bytesArrived(now: 1120)
        #expect(deadline.passed(now: 1120))
        #expect(deadline.reason == "idle_before_hello")
    }
}

private let claude = AppIdentity.signed(SigningIdentity(signingID: "com.anthropic.claude-code", teamID: "Q6L2SF6YDW"))
private let browser = AppIdentity.signed(SigningIdentity(signingID: "com.example.browser", teamID: "ABCDE12345"))
private let flooder = AppIdentity.cdhash(testCDHash)

/// A flow held at `heldAt`, quiet unless its hello started at `firstByte`.
private func held(_ id: Int, _ app: AppIdentity, at heldAt: TimeInterval, firstByte: TimeInterval? = nil) -> HeldPlace<Int> {
    var deadline = HelloDeadline(heldAt: heldAt)
    if let firstByte { deadline.bytesArrived(now: firstByte) }
    return HeldPlace(id: id, app: app, deadline: deadline)
}

@Suite struct HoldPoolTests {
    @Test func oneAppHoldsAQuarterOfThePool() {
        #expect(HoldPool.capacity == 256 && HoldPool.share == HoldPool.capacity / 4)
    }

    /// On the Mac, Claude Code's sockets that were gone left their entries quiet for 120 s, about
    /// 70 at once. Its next connection, a real one, takes the oldest one's place.
    @Test func phantomEntriesGiveWayToTheAppsNewFlow() {
        let phantoms = (0..<HoldPool.share).map { held($0, claude, at: TimeInterval(100 + $0)) }
        #expect(HoldPool.admit(claude, held: phantoms) == .hold(evicting: 0))
        // Another app is under its share and the pool has room: nothing goes.
        #expect(HoldPool.admit(browser, held: phantoms) == .hold(evicting: nil))
        // Under its share, the app takes a free place too.
        #expect(HoldPool.admit(claude, held: Array(phantoms.dropLast())) == .hold(evicting: nil))
    }

    @Test func aHelloThatStartedKeepsItsPlace() {
        // The oldest has sent its first bytes: the oldest quiet one goes instead.
        var flows = (0..<4).map { held($0, claude, at: TimeInterval($0)) }
        flows[0] = held(0, claude, at: 0, firstByte: 5)
        #expect(HoldPool.admit(claude, held: flows, share: 4) == .hold(evicting: 1))
        // None quiet: the new flow is dropped, and its app's other flows keep their places.
        let started = (0..<4).map { held($0, claude, at: TimeInterval($0), firstByte: 10) }
        #expect(HoldPool.admit(claude, held: started, share: 4) == .refuse("hold_capacity_app"))
        // Only the app's own quiet flows count: another app's quiet one stays.
        #expect(HoldPool.admit(claude, held: started + [held(9, browser, at: 0)], share: 4) == .refuse("hold_capacity_app"))
    }

    /// An app that opens connections and writes nothing only displaces its own.
    @Test func aFloodDisplacesOnlyItsOwnFlows() {
        var pool = [held(0, browser, at: 0), held(1, claude, at: 1)]
        for id in 2..<(2 + HoldPool.share) { pool.append(held(id, flooder, at: TimeInterval(id))) }
        #expect(HoldPool.admit(flooder, held: pool) == .hold(evicting: 2))
        #expect(HoldPool.admit(browser, held: pool) == .hold(evicting: nil))
        #expect(HoldPool.admit(claude, held: pool) == .hold(evicting: nil))
    }

    /// With every place taken, the app that holds the most gives up its oldest quiet flow, whoever the
    /// new flow is for.
    @Test func aFullPoolTakesFromTheAppThatHoldsTheMost() {
        let other = AppIdentity.signed(SigningIdentity(signingID: "com.example.other", teamID: "ABCDE12345"))
        let pool = [held(0, browser, at: 0), held(1, browser, at: 1, firstByte: 2), held(2, browser, at: 3),
                    held(3, claude, at: 4), held(4, claude, at: 5),
                    held(5, flooder, at: 6, firstByte: 7)]
        #expect(HoldPool.admit(other, held: pool, capacity: 6, share: 4) == .hold(evicting: 0))
        // Of the apps with a quiet flow: the one holding the most has none quiet, so the next one gives.
        let started = [held(0, browser, at: 0, firstByte: 1), held(1, browser, at: 1, firstByte: 2),
                       held(2, browser, at: 2, firstByte: 3), held(3, claude, at: 9), held(4, claude, at: 5),
                       held(5, flooder, at: 4)]
        #expect(HoldPool.admit(other, held: started, capacity: 6, share: 4) == .hold(evicting: 4))
        // Apps holding as many: the oldest quiet flow of either.
        let even = [held(0, claude, at: 8), held(1, claude, at: 9), held(2, flooder, at: 7), held(3, flooder, at: 10)]
        #expect(HoldPool.admit(browser, held: even, capacity: 4, share: 4) == .hold(evicting: 2))
        // Nothing quiet anywhere: the new flow is dropped.
        let busy = (0..<4).map { held($0, $0 < 2 ? claude : flooder, at: 0, firstByte: 1) }
        #expect(HoldPool.admit(browser, held: busy, capacity: 4, share: 4) == .refuse("hold_capacity"))
    }
}
