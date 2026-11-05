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
