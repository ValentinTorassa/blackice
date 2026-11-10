import Foundation
import Testing
@testable import BlackiceCore

// Ask mode's state: approvals, pending events, dedup, tokens, answers and the timeout, with
// strings standing in for paused flows and a clock passed in by hand.

private let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
private let other = AppIdentity.signed(SigningIdentity(signingID: "com.example.other", teamID: "ABCDE12345"))
private let build = AppIdentity.cdhash(testCDHash)

/// Events with predictable IDs and fresh tokens.
private final class EventMaker: @unchecked Sendable {
    private var next = 0
    private(set) var tokens: [String: String] = [:]

    func make(_ key: PendingKey) -> (TimeInterval) throws -> HookEvent {
        { seconds in
            self.next += 1
            let id = String(format: "ev-%08x", self.next)
            let token = try EventToken.generate()
            self.tokens[id] = token
            return HookEvent(id: id, token: token, app: HookEvent.App(key.identity, path: "/tmp/tool"), host: key.host,
                             ip: "203.0.113.7", port: key.port, deadline: Date().addingTimeInterval(seconds))
        }
    }
}

private func pendingKey(_ identity: AppIdentity = tool, _ host: String = "example.com", _ port: UInt16 = 443) -> PendingKey {
    PendingKey(identity: identity, host: host, port: port)
}

private func request(_ kind: AnswerRequest.Kind, _ identity: AppIdentity = tool, host: String = "example.com",
                     seconds: Int? = 600, token: String? = nil) -> AnswerRequest {
    AnswerRequest(kind: kind, app: identity, host: host, seconds: kind == .approve ? seconds : nil, token: token)
}

struct ApprovalTableTests {
    /// The filter's clock counts sleep: since boot it is never behind the uptime, which does not,
    /// and it does not go back.
    @Test func theFiltersClockCountsSleep() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let first = continuousSeconds()
        #expect(first >= uptime - 1)
        #expect(continuousSeconds() >= first)
    }

    @Test func approvalsExpire() {
        var table = ApprovalTable()
        let key = ApprovalKey(identity: tool, host: "example.com")
        #expect(!table.covers(key, now: 0))
        #expect(table.add(key, seconds: 600, now: 100) == 700)
        #expect(table.covers(key, now: 699.9))
        #expect(!table.covers(key, now: 700))
        // Another app, host or cdhash is not covered.
        #expect(!table.covers(ApprovalKey(identity: other, host: "example.com"), now: 200))
        #expect(!table.covers(ApprovalKey(identity: tool, host: "www.example.com"), now: 200))
        table.expire(now: 700)
        #expect(table.count == 0)
    }

    @Test func durationIsCappedAndNeverShortened() {
        var table = ApprovalTable()
        let key = ApprovalKey(identity: build, host: "example.com")
        #expect(table.add(key, seconds: 1_000_000, now: 0) == TimeInterval(ApprovalTable.maximumSeconds))
        #expect(table.add(key, seconds: 60, now: 10) == TimeInterval(ApprovalTable.maximumSeconds))
        var fresh = ApprovalTable()
        #expect(fresh.add(key, seconds: 0, now: 5) == 6)
        #expect(fresh.remove(key) && !fresh.remove(key))
    }

    @Test func fullTableDropsTheApprovalClosestToExpiring() {
        var table = ApprovalTable()
        for index in 0..<ApprovalTable.maximumEntries {
            table.add(ApprovalKey(identity: tool, host: "h\(index).example.com"), seconds: 1000 + index, now: 0)
        }
        table.add(ApprovalKey(identity: tool, host: "new.example.com"), seconds: 60, now: 0)
        #expect(table.count == ApprovalTable.maximumEntries)
        #expect(!table.covers(ApprovalKey(identity: tool, host: "h0.example.com"), now: 1))
        #expect(table.covers(ApprovalKey(identity: tool, host: "new.example.com"), now: 1))
    }

    @Test func summariesShowTimeLeft() {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: build, host: "example.com"), seconds: 90, now: 0)
        #expect(table.summaries(now: 30) == [ApprovalSummary(app: AppReference(build), host: "example.com", secondsLeft: 60)])
        #expect(table.summaries(now: 90).isEmpty)
    }

    @Test func eachChangeAndOnlyAChangeMovesTheRevision() {
        var table = ApprovalTable()
        let key = ApprovalKey(identity: tool, host: "example.com")
        table.add(key, seconds: 60, now: 0)
        #expect(table.revision == 1)
        table.expire(now: 30)
        let removed = table.remove(ApprovalKey(identity: other, host: "example.com"))
        let removedCovered = table.removeCovered(by: ApprovalKey(identity: other, host: "example.com"))
        #expect(!removed && !removedCovered)
        var empty = ApprovalTable()
        empty.removeAll()
        #expect(table.revision == 1 && empty.revision == 0)
        table.expire(now: 60)
        #expect(table.revision == 2)
        table.add(key, seconds: 60, now: 60)
        let revoked = table.removeCovered(by: key)
        #expect(revoked && table.revision == 4)
    }

    // Its host names an interface by its number, which a restart may give to another interface.
    @Test func anApprovalForALinkLocalAddressIsNotSaved() throws {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: tool, host: "fe80::1%7"), seconds: 3600, now: 0)
        table.add(ApprovalKey(identity: tool, host: "2001:db8::1"), seconds: 3600, now: 0)
        table.add(ApprovalKey(identity: tool, host: "192.0.2.7"), seconds: 3600, now: 0)
        table.add(ApprovalKey(identity: tool, host: "example.com"), seconds: 3600, now: 0)
        #expect(table.covers(ApprovalKey(identity: tool, host: "fe80::1%7"), now: 1))
        var restored = ApprovalTable()
        let added = restored.restore(try #require(table.saved(now: 0, timeOfDay: 1_000_000)), now: 0, timeOfDay: 1_000_000)
        #expect(added == 3 && !restored.covers(ApprovalKey(identity: tool, host: "fe80::1%7"), now: 1))
        #expect(restored.summaries(now: 0).map(\.host).sorted() == ["192.0.2.7", "2001:db8::1", "example.com"])
    }

    // An upgrade or a restart of the Mac: what was left when saved, less the time of day since.
    @Test func savedApprovalsComeBackWithWhatTheyHadLeft() throws {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: tool, host: "example.com"), seconds: 3600, now: 100)
        table.add(ApprovalKey(identity: build, host: "api.example.com"), seconds: 600, now: 100)
        table.add(ApprovalKey(identity: tool, host: "pypi.org", scope: .script("/opt/tool/cli.py")), seconds: 1500, now: 100)
        table.add(ApprovalKey(identity: tool, host: "files.example.com", scope: .script(nil)), seconds: 1500, now: 100)
        let data = try #require(table.saved(now: 400, timeOfDay: 1_000_000))

        // 700 s of the time of day later, on a clock that started again (a restart).
        var restored = ApprovalTable()
        let added = restored.restore(data, now: 5, timeOfDay: 1_000_700)
        #expect(added == 3)
        #expect(restored.summaries(now: 5).map(\.secondsLeft).sorted() == [500, 500, 2600])
        #expect(restored.covers(ApprovalKey(identity: tool, host: "example.com"), now: 2604))
        #expect(!restored.covers(ApprovalKey(identity: tool, host: "example.com"), now: 2605))
        #expect(restored.covers(tool, host: "pypi.org", scope: .script("/opt/tool/cli.py"), now: 5))
        #expect(!restored.covers(tool, host: "pypi.org", scope: .script("/opt/tool/other.py"), now: 5))
        #expect(restored.covers(tool, host: "files.example.com", scope: .script(nil), now: 5))
        // build's 300 s left were gone.
        #expect(!restored.covers(ApprovalKey(identity: build, host: "api.example.com"), now: 5))
    }

    @Test func aClockSetBackNeverLengthensASavedApproval() throws {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: tool, host: "example.com"), seconds: 600, now: 0)
        let data = try #require(table.saved(now: 0, timeOfDay: 1_000_000))
        var restored = ApprovalTable()
        let added = restored.restore(data, now: 0, timeOfDay: 900_000)
        #expect(added == 1)
        #expect(restored.summaries(now: 0).map(\.secondsLeft) == [600])
    }

    // What the table can hold comes back: an ad hoc build, an address as the host, and the longest approval.
    @Test func everyKindOfApprovalRoundTrips() throws {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: build, host: "203.0.113.7"), seconds: 600, now: 0)
        table.add(ApprovalKey(identity: tool, host: "example.com"), seconds: ApprovalTable.maximumSeconds, now: 0)
        let data = try #require(table.saved(now: 0, timeOfDay: 1_000_000))
        var restored = ApprovalTable()
        let added = restored.restore(data, now: 50, timeOfDay: 1_000_000)
        #expect(added == 2 && restored.revision == 2)
        #expect(restored.covers(ApprovalKey(identity: build, host: "203.0.113.7"), now: 649))
        #expect(restored.covers(ApprovalKey(identity: tool, host: "example.com"), now: 50 + 86_399))
        #expect(!restored.covers(ApprovalKey(identity: tool, host: "example.com"), now: 50 + 86_400))
    }

    @Test func aRepeatedEntryKeepsTheLongerOneAndTooManyAddNothing() {
        func entry(_ host: String, _ seconds: Int) -> String {
            #"{"app":{"signing_id":"com.example.tool","team_id":"ABCDE12345"},"host":"\#(host)","seconds_left":\#(seconds)}"#
        }
        func file(_ entries: [String]) -> Data {
            Data(#"{"version":1,"saved_at":1000000,"approvals":[\#(entries.joined(separator: ","))]}"#.utf8)
        }
        var table = ApprovalTable()
        let added = table.restore(file([entry("example.com", 60), entry("example.com", 600), entry("example.com", 30)]),
                                  now: 0, timeOfDay: 1_000_000)
        #expect(added == 3 && table.count == 1)
        #expect(table.summaries(now: 0).map(\.secondsLeft) == [600])

        var full = ApprovalTable()
        let many = (0...ApprovalTable.maximumEntries).map { entry("h\($0).example.com", 60) }
        let tooMany = full.restore(file(many), now: 0, timeOfDay: 1_000_000)
        #expect(tooMany == nil && full.count == 0)
    }

    // Less than a second left is gone, and a file saved in the future loses nothing.
    @Test func whatIsLeftIsCountedInWholeSeconds() throws {
        var table = ApprovalTable()
        table.add(ApprovalKey(identity: tool, host: "example.com"), seconds: 60, now: 0)
        let data = try #require(table.saved(now: 0, timeOfDay: 1_000_000))
        var almostGone = ApprovalTable()
        let none = almostGone.restore(data, now: 0, timeOfDay: 1_000_059.5)
        #expect(none == 0 && almostGone.count == 0)
        var oneLeft = ApprovalTable()
        let one = oneLeft.restore(data, now: 0, timeOfDay: 1_000_058.5)
        #expect(one == 1 && oneLeft.summaries(now: 0).map(\.secondsLeft) == [1])
    }

    @Test func aFileWithAnInvalidEntryOrAnotherVersionAddsNothing() throws {
        func file(version: Int = 1, _ approvals: String) -> Data {
            Data(#"{"version":\#(version),"saved_at":1000000,"approvals":[\#(approvals)]}"#.utf8)
        }
        let good = #"{"app":{"signing_id":"com.example.tool","team_id":"ABCDE12345"},"host":"example.com","seconds_left":60}"#
        var table = ApprovalTable()
        let added = table.restore(file(good), now: 0, timeOfDay: 1_000_000)
        #expect(added == 1)
        let bad = [
            #"{"app":{"signing_id":"com.example.tool","cdhash":"\#(testCDHash)"},"host":"example.com","seconds_left":60}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"Example.COM","seconds_left":60}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"example.com","seconds_left":-1}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"example.com","seconds_left":86401}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"example.com","seconds_left":60,"script":"/opt/a\u0001.py"}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"example.com","seconds_left":60,"no_script":false}"#,
            #"{"app":{"signing_id":"com.example.tool"},"host":"example.com","seconds_left":60,"script":"/opt/a.py","no_script":true}"#,
        ]
        for entry in bad {
            var fresh = ApprovalTable()
            let added = fresh.restore(file(good + "," + entry), now: 0, timeOfDay: 1_000_000)
            #expect(added == nil && fresh.count == 0)
        }
        var fresh = ApprovalTable()
        let otherVersion = fresh.restore(file(version: 2, good), now: 0, timeOfDay: 1_000_000)
        let notJSON = fresh.restore(Data("not json".utf8), now: 0, timeOfDay: 1_000_000)
        #expect(otherVersion == nil && notJSON == nil && fresh.count == 0)
    }
}

struct PendingTableTests {
    @Test func repeatedConnectionsShareOneEvent() throws {
        var table = PendingTable<String>()
        let maker = EventMaker()
        let key = pendingKey()
        guard case .raised(let event) = table.add("flow-1", key: key, addressMatches: true, now: 0, timeout: 10,
                                                  makeEvent: maker.make(key)) else { Issue.record("not raised"); return }
        #expect(event.host == "example.com" && event.port == 443 && event.app.identity == tool)
        #expect(table.add("flow-2", key: key, addressMatches: true, now: 1, timeout: 10, makeEvent: maker.make(key))
            == .joined(eventID: event.id))
        // Another port or another app is another event.
        let port = pendingKey(tool, "example.com", 8443)
        guard case .raised = table.add("flow-3", key: port, addressMatches: true, now: 1, timeout: 10, makeEvent: maker.make(port))
        else { Issue.record("other port joined"); return }
        let adHoc = pendingKey(build)
        guard case .raised(let built) = table.add("flow-4", key: adHoc, addressMatches: true, now: 1, timeout: 10,
                                                  makeEvent: maker.make(adHoc)) else { Issue.record("not raised"); return }
        #expect(built.app.cdhash == testCDHash && built.app.signingID == nil)
        #expect(table.eventCount == 3 && table.flowCount == 4)
        #expect(table.entry(event.id)?.flows.map(\.flow) == ["flow-1", "flow-2"])
    }

    @Test func limitsDropInsteadOfGrowing() {
        var table = PendingTable<Int>(maximumEvents: 2, maximumFlows: 4, maximumFlowsPerEvent: 2)
        let maker = EventMaker()
        let a = pendingKey(tool, "a.example.com"), b = pendingKey(tool, "b.example.com"), c = pendingKey(tool, "c.example.com")
        _ = table.add(1, key: a, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(a))
        _ = table.add(2, key: a, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(a))
        #expect(table.add(3, key: a, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(a)) == .full)
        _ = table.add(4, key: b, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(b))
        #expect(table.add(5, key: c, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(c)) == .full)
        _ = table.add(6, key: b, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(b))
        #expect(table.flowCount == 4)
        #expect(table.add(7, key: b, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(b)) == .full)
        // No randomness, no event.
        var broken = PendingTable<Int>()
        #expect(broken.add(1, key: a, addressMatches: true, now: 0, timeout: 10,
                           makeEvent: { _ in throw EventToken.RandomFailure(status: -1) }) == .full)
    }

    /// One app that connects to many hosts, or to many ports, no longer fills the table for every
    /// other app: it gets a quarter of the events and of the flows.
    @Test func oneAppTakesAtMostItsShare() {
        #expect(AskLimits.eventsPerApp == 64 && AskLimits.flowsPerApp == 256)
        let defaults = PendingTable<Int>()
        #expect(defaults.maximumEventsPerApp == AskLimits.eventsPerApp && defaults.maximumFlowsPerApp == AskLimits.flowsPerApp)
        var table = PendingTable<Int>(maximumEvents: 8, maximumFlows: 16, maximumFlowsPerEvent: 8,
                                      maximumEventsPerApp: 2, maximumFlowsPerApp: 3)
        let maker = EventMaker()
        func add(_ flow: Int, _ key: PendingKey, holdFor: TimeInterval? = nil) -> PendingTable<Int>.Added {
            table.add(flow, key: key, addressMatches: true, now: 0, timeout: 10, holdFor: holdFor, makeEvent: maker.make(key))
        }
        let a = pendingKey(tool, "a.example.com"), b = pendingKey(tool, "b.example.com", 8443)
        let c = pendingKey(tool, "b.example.com", 8444)
        guard case .raised = add(1, a, holdFor: 5), case .raised = add(2, b) else { Issue.record("not raised"); return }
        // A third event for the same app is one too many, another app still raises its own...
        #expect(add(3, c) == .appFull)
        guard case .raised = add(4, pendingKey(other, "b.example.com", 8444)) else { Issue.record("not raised"); return }
        // ...and the app's flows count on all of its events.
        guard case .joined = add(5, b) else { Issue.record("not joined"); return }
        #expect(add(6, b) == .appFull && table.flowCount == 4)
        // A flow whose hold ran out makes room. Its event stays until its deadline, and still counts.
        #expect(table.expireHolds(now: 5).map(\.flow) == [1])
        #expect(add(7, c) == .appFull)
        guard case .joined = add(8, a) else { Issue.record("not joined"); return }
        // Once its events end, the app has room again.
        #expect(table.expire(now: 10).count == 3)
        guard case .raised = add(9, c) else { Issue.record("not raised"); return }
    }

    @Test func eventIDCollisionsAreRetried() throws {
        var table = PendingTable<Int>()
        var attempts = 0
        let fixed = { (key: PendingKey) -> (TimeInterval) throws -> HookEvent in
            { _ in
                attempts += 1
                return HookEvent(id: attempts < 3 ? "ev-00000001" : "ev-00000002", token: try EventToken.generate(),
                                 app: .init(key.identity, path: nil), host: key.host, ip: "203.0.113.7", port: key.port,
                                 deadline: Date())
            }
        }
        let a = pendingKey(tool, "a.example.com"), b = pendingKey(tool, "b.example.com")
        _ = table.add(1, key: a, addressMatches: true, now: 0, timeout: 10, makeEvent: fixed(a))
        guard case .raised(let event) = table.add(2, key: b, addressMatches: true, now: 0, timeout: 10, makeEvent: fixed(b)) else {
            Issue.record("not raised"); return
        }
        #expect(event.id == "ev-00000002")
    }

    @Test func deadlinePassesThenEverythingGoes() {
        var table = PendingTable<String>()
        let maker = EventMaker()
        let key = pendingKey()
        _ = table.add("first", key: key, addressMatches: true, now: 100, timeout: 10, makeEvent: maker.make(key))
        // A repeat that joins later still ends at the first one's deadline.
        _ = table.add("late", key: key, addressMatches: true, now: 108, timeout: 10, makeEvent: maker.make(key))
        #expect(table.expire(now: 109.9).isEmpty)
        let expired = table.expire(now: 110)
        #expect(expired.count == 1 && expired[0].flows.map(\.flow) == ["first", "late"])
        #expect(table.eventCount == 0 && table.flowCount == 0)
        // The next connection raises a new event.
        guard case .raised = table.add("again", key: key, addressMatches: true, now: 111, timeout: 10, makeEvent: maker.make(key))
        else { Issue.record("not raised"); return }
    }

    @Test func tokensAreSingleUseBoundAndExpire() throws {
        var table = PendingTable<String>()
        let maker = EventMaker()
        let key = pendingKey()
        guard case .raised(let event) = table.add("f", key: key, addressMatches: true, now: 0, timeout: 10,
                                                  makeEvent: maker.make(key)) else { Issue.record("not raised"); return }
        #expect(table.spendToken(try EventToken.generate(), now: 1) == .unknown)
        #expect(table.spendToken(String(event.token.dropLast()), now: 1) == .unknown)
        #expect(table.spendToken(event.token, now: 1) == .valid(eventID: event.id, key: key))
        #expect(table.spendToken(event.token, now: 2) == .spent)

        let late = pendingKey(tool, "late.example.com")
        guard case .raised(let second) = table.add("g", key: late, addressMatches: true, now: 0, timeout: 10,
                                                   makeEvent: maker.make(late)) else { Issue.record("not raised"); return }
        #expect(table.spendToken(second.token, now: 10) == .expired)
        #expect(table.spendToken(second.token, now: 10) == .spent)
        // Once the event is gone, so is its token.
        _ = table.expire(now: 10)
        #expect(table.spendToken(second.token, now: 10) == .unknown)
    }

    @Test func summariesNeverCarryTokens() throws {
        var table = PendingTable<String>()
        let maker = EventMaker()
        let key = pendingKey()
        guard case .raised(let event) = table.add("f", key: key, addressMatches: true, now: 0, timeout: 10,
                                                  makeEvent: maker.make(key)) else { Issue.record("not raised"); return }
        _ = table.add("g", key: key, addressMatches: true, now: 0, timeout: 10, makeEvent: maker.make(key))
        let summaries = table.summaries(now: 2.5)
        #expect(summaries == [PendingSummary(id: event.id, app: AppReference(tool), path: "/tmp/tool", host: "example.com",
                                             ip: "203.0.113.7", port: 443, secondsLeft: 8, connections: 2)])
        let json = String(decoding: try Messages.encode(PendingReply(events: summaries, approvals: [])), as: UTF8.self)
        #expect(!json.contains(event.token) && !json.contains("token"))
    }
}

struct AskStateTests {
    /// Two paused flows for tool -> example.com (one whose address did not match), one on
    /// another port, and one for another host.
    private func state() -> (AskState<String>, EventMaker, [String: HookEvent]) {
        var ask = AskState<String>()
        let maker = EventMaker()
        var events: [String: HookEvent] = [:]
        let flows: [(String, PendingKey, Bool)] = [
            ("a1", pendingKey(), true), ("a2", pendingKey(), false),
            ("port", pendingKey(tool, "example.com", 8443), true),
            ("host", pendingKey(tool, "other.example.com"), true),
        ]
        for (name, key, matches) in flows {
            if case .raised(let event) = ask.pending.add(name, key: key, addressMatches: matches, now: 0, timeout: 10,
                                                         makeEvent: maker.make(key)) {
                events[name] = event
            }
        }
        return (ask, maker, events)
    }

    @Test func approveWithTheTokenReleasesThatAppAndHost() throws {
        var (ask, _, events) = state()
        let token = try #require(events["a1"]?.token)
        let outcome = ask.answer(request(.approve, seconds: 600, token: token), now: 1)
        #expect(outcome.reply.status == .done && outcome.reply.reason == "approved")
        // Every port for that host, and the flow whose address did not match is dropped instead.
        let released = Dictionary(uniqueKeysWithValues: outcome.released.map { ($0.flow, ($0.allow, $0.reason)) })
        #expect(released.count == 3)
        #expect(released["a1"]! == (true, "approved") && released["port"]! == (true, "approved"))
        #expect(released["a2"]! == (false, "approved;address_mismatch"))
        #expect(Set(outcome.verdicts.map(\.eventID)) == Set([events["a1"]!.id, events["port"]!.id]))
        #expect(outcome.verdicts.allSatisfy { $0.verdict == .approved })
        #expect(ask.approvals.covers(ApprovalKey(identity: tool, host: "example.com"), now: 600))
        #expect(!ask.approvals.covers(ApprovalKey(identity: tool, host: "example.com"), now: 601))
        // The other host still waits, and the spent token cannot answer again.
        #expect(ask.pending.eventCount == 1)
        #expect(ask.answer(request(.approve, token: token), now: 2).reply.reason == "token_unknown")
    }

    @Test func aTokenOnlyAnswersItsOwnAppAndHost() throws {
        var (ask, _, events) = state()
        let token = try #require(events["host"]?.token)
        // Presenting it for another host refuses and spends it; nothing is released or approved.
        let wrongHost = ask.answer(request(.approve, host: "example.com", token: token), now: 1)
        #expect(wrongHost.reply.status == .refused && wrongHost.reply.reason == "token_mismatch")
        #expect(wrongHost.released.isEmpty && ask.approvals.count == 0)
        #expect(ask.answer(request(.approve, host: "other.example.com", token: token), now: 1).reply.reason == "token_spent")
        // Another app, same token shape.
        let second = try #require(events["a1"]?.token)
        #expect(ask.answer(request(.deny, other, token: second), now: 1).reply.reason == "token_mismatch")
        #expect(ask.pending.eventCount == 3)
    }

    @Test func expiredTokensAreRefused() throws {
        var (ask, _, events) = state()
        let token = try #require(events["a1"]?.token)
        let outcome = ask.answer(request(.approve, token: token), now: 10)
        #expect(outcome.reply.reason == "token_expired" && outcome.released.isEmpty)
        #expect(ask.answer(request(.approve, token: "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys"), now: 1).reply.reason
            == "token_unknown")
    }

    @Test func denyDropsAndRevokes() throws {
        var (ask, _, events) = state()
        _ = ask.answer(request(.approve, host: "other.example.com", seconds: 3600), now: 1)
        #expect(ask.approvals.covers(ApprovalKey(identity: tool, host: "other.example.com"), now: 2))
        let outcome = ask.answer(request(.deny, token: try #require(events["a1"]?.token)), now: 2)
        #expect(outcome.reply.reason == "denied" && outcome.released.count == 3)
        #expect(outcome.released.allSatisfy { !$0.allow && $0.reason == "denied" })
        #expect(outcome.verdicts.allSatisfy { $0.verdict == .denied })
        // A person's deny removes the approval too.
        let revoke = ask.answer(request(.deny, host: "other.example.com"), now: 3)
        #expect(revoke.reply.message.contains("removing its approval"))
        #expect(!ask.approvals.covers(ApprovalKey(identity: tool, host: "other.example.com"), now: 4))
    }

    @Test func aDenialIsRememberedForTenMinutes() throws {
        var (ask, _, events) = state()
        let key = ApprovalKey(identity: tool, host: "example.com")
        // A hook's deny, sent with the event's token.
        let outcome = ask.answer(request(.deny, token: try #require(events["a1"]?.token)), now: 2)
        #expect(outcome.reply.message.hasPrefix("Denied com.example.tool (ABCDE12345) → example.com for 10m;"))
        #expect(ask.denials.covers(key, now: 601.9) && !ask.denials.covers(key, now: 602))
        #expect(ask.denials.summaries(now: 2) == [ApprovalSummary(app: AppReference(tool), host: "example.com", secondsLeft: 600)])
        // Only that app and that host.
        #expect(!ask.denials.covers(ApprovalKey(identity: tool, host: "other.example.com"), now: 3))
        #expect(!ask.denials.covers(ApprovalKey(identity: other, host: "example.com"), now: 3))
        // A person's deny (Touch ID) starts the 10 minutes again.
        _ = ask.answer(request(.deny), now: 300)
        #expect(ask.denials.covers(key, now: 899))
        _ = ask.expire(now: 900)
        #expect(ask.denials.count == 0)
    }

    @Test func anApprovalReplacesADenial() {
        var ask = AskState<String>()
        let key = ApprovalKey(identity: build, host: "example.org")
        _ = ask.answer(request(.deny, build, host: "example.org"), now: 0)
        #expect(ask.denials.covers(key, now: 1))
        let approved = ask.answer(request(.approve, build, host: "example.org", seconds: 60), now: 1)
        #expect(approved.reply.message.contains("replacing its denial"))
        #expect(!ask.denials.covers(key, now: 2) && ask.approvals.covers(key, now: 2))
        // A deny replaces the approval, as before, and is remembered again.
        let denied = ask.answer(request(.deny, build, host: "example.org"), now: 3)
        #expect(denied.reply.message.contains("removing its approval"))
        #expect(ask.denials.covers(key, now: 4) && !ask.approvals.covers(key, now: 4))
    }

    @Test func noAnswerIsNoDenial() throws {
        var (timedOut, _, _) = state()
        _ = timedOut.expire(now: 10)
        #expect(timedOut.denials.count == 0)
        // A refused answer remembers nothing: this token belongs to another host.
        var (refused, _, events) = state()
        let reply = refused.answer(request(.deny, host: "example.com", token: try #require(events["host"]?.token)), now: 1)
        #expect(reply.reply.reason == "token_mismatch" && refused.denials.count == 0)
    }

    @Test func aConfigurationChangeEndsEventsAndForgetsDenials() {
        var (ask, _, _) = state()
        _ = ask.answer(request(.deny, host: "other.example.com"), now: 1)
        _ = ask.answer(request(.approve, other, host: "example.org", seconds: 600), now: 1)
        let ended = ask.endAll()
        #expect(ended.flatMap { $0.flows.map(\.flow) }.sorted() == ["a1", "a2", "port"])
        #expect(ask.pending.eventCount == 0 && ask.denials.count == 0)
        // Approvals stay as they were.
        #expect(ask.approvals.covers(ApprovalKey(identity: other, host: "example.org"), now: 2))
    }

    @Test func forgettingTakesEveryApprovalAndNothingElse() throws {
        var (ask, _, _) = state()
        _ = ask.answer(request(.deny, host: "other.example.com"), now: 1)
        _ = ask.answer(request(.approve, other, host: "example.org", seconds: 600), now: 1)
        _ = ask.answer(AnswerRequest(kind: .approve, app: build, host: "pypi.org", seconds: 600, token: nil, script: "/opt/tool.py"),
                       now: 1)
        _ = ask.answer(request(.approve, other, host: "short.example.org", seconds: 5), now: 1)
        let events = ask.pending.eventCount
        let revision = ask.approvals.revision
        // The one that ran out at 6 s is not counted.
        #expect(ask.forgetApprovals(now: 10) == 2)
        #expect(ask.approvals.count == 0 && ask.approvals.revision > revision)
        #expect(!ask.approvals.covers(ApprovalKey(identity: other, host: "example.org"), now: 10))
        // What waits and the remembered denial stay.
        #expect(events > 0 && ask.pending.eventCount == events && ask.denials.count == 1)
        // The file written next holds none, so a restart brings none back.
        var restored = ApprovalTable()
        let data = try #require(ask.approvals.saved(now: 10, timeOfDay: 1_000_000))
        #expect(restored.restore(data, now: 0, timeOfDay: 1_000_000) == 0 && restored.count == 0)
        // Again, with nothing left.
        let again = ask.approvals.revision
        #expect(ask.forgetApprovals(now: 11) == 0 && ask.approvals.revision == again)
        #expect(AnswerReply.forgotten(2).message == "Forgot 2 approvals" && AnswerReply.forgotten(1).message == "Forgot 1 approval")
        #expect(AnswerReply.forgotten(0).message == "There were no approvals to forget")
        for count in [0, 1, 2] {
            let reply = AnswerReply.forgotten(count)
            #expect(reply.status == .done && reply.reason == "forgotten" && reply.events.isEmpty && reply.released == 0)
            #expect(try Messages.decode(AnswerReply.self, from: Messages.encode(reply)) == reply)
        }
    }

    @Test func aPersonMayApproveWithoutAnEvent() {
        var ask = AskState<String>()
        let outcome = ask.answer(request(.approve, build, host: "example.org", seconds: 60), now: 0)
        #expect(outcome.reply.status == .done && outcome.released.isEmpty)
        #expect(outcome.reply.message.contains("nothing was waiting"))
        #expect(ask.approvals.covers(ApprovalKey(identity: build, host: "example.org"), now: 59))
    }

    @Test func timeoutDropsTheFlowsAndForgetsApprovals() {
        var (ask, _, events) = state()
        ask.approvals.add(ApprovalKey(identity: other, host: "example.com"), seconds: 5, now: 0)
        #expect(ask.expire(now: 9).released.isEmpty)
        let (released, timedOut) = ask.expire(now: 10)
        #expect(released.count == 4 && released.allSatisfy { !$0.allow && $0.reason == "timeout" })
        #expect(Set(timedOut) == Set(events.values.map(\.id)))
        #expect(ask.pending.eventCount == 0 && ask.approvals.count == 0)
    }

    @Test func holdExpiredDropsTheFlowAndKeepsTheEvent() throws {
        var ask = AskState<String>()
        let maker = EventMaker()
        let key = pendingKey()
        // A curl the server will hang up on, and a connection that can wait the whole timeout.
        guard case .raised(let event) = ask.pending.add("curl-1", key: key, addressMatches: true, now: 0, timeout: 60,
                                                        holdFor: 8, makeEvent: maker.make(key)) else {
            Issue.record("not raised"); return
        }
        _ = ask.pending.add("named", key: key, addressMatches: true, now: 1, timeout: 60, makeEvent: maker.make(key))
        #expect(ask.expire(now: 7.5).released.isEmpty)
        let (released, timedOut) = ask.expire(now: 8)
        #expect(released.count == 1 && released[0].flow == "curl-1" && !released[0].allow)
        #expect(released[0].reason == "hold_expired" && released[0].eventID == event.id)
        #expect(timedOut.isEmpty && ask.pending.eventCount == 1 && ask.pending.flowCount == 1)
        #expect(ask.pending.summaries(now: 8).first?.connections == 1)
        // The app tries again: the retry joins the same event, with its own hold.
        #expect(ask.pending.add("curl-2", key: key, addressMatches: true, now: 12, timeout: 60, holdFor: 8,
                                makeEvent: maker.make(key)) == .joined(eventID: event.id))
        // The agent answers after 15 s with the event's token, which still counts.
        let outcome = ask.answer(request(.approve, token: event.token), now: 15)
        #expect(outcome.reply.status == .done && outcome.verdicts.map(\.eventID) == [event.id])
        #expect(Set(outcome.released.map(\.flow)) == ["named", "curl-2"] && outcome.released.allSatisfy(\.allow))
        #expect(ask.approvals.covers(ApprovalKey(identity: tool, host: "example.com"), now: 16))
    }

    @Test func anEventWithNoFlowLeftStillTakesItsAnswer() throws {
        var ask = AskState<String>()
        let maker = EventMaker()
        let key = pendingKey()
        guard case .raised(let event) = ask.pending.add("curl", key: key, addressMatches: true, now: 0, timeout: 60,
                                                        holdFor: 8, makeEvent: maker.make(key)) else {
            Issue.record("not raised"); return
        }
        #expect(ask.expire(now: 8).released.map(\.reason) == ["hold_expired"])
        #expect(ask.pending.eventCount == 1 && ask.pending.flowCount == 0)
        #expect(ask.pending.summaries(now: 9).first?.connections == 0)
        // Approved: nothing to release, but the approval covers the app's next connection.
        let outcome = ask.answer(request(.approve, seconds: 600, token: event.token), now: 20)
        #expect(outcome.reply.status == .done && outcome.released.isEmpty)
        #expect(outcome.reply.message.contains("nothing was waiting"))
        #expect(outcome.verdicts.map(\.eventID) == [event.id] && ask.pending.eventCount == 0)
        #expect(ask.approvals.covers(ApprovalKey(identity: tool, host: "example.com"), now: 21))

        // Unanswered, such an event still times out at its deadline.
        var unanswered = AskState<String>()
        guard case .raised(let late) = unanswered.pending.add("curl", key: key, addressMatches: true, now: 0, timeout: 60,
                                                              holdFor: 8, makeEvent: maker.make(key)) else {
            Issue.record("not raised"); return
        }
        _ = unanswered.expire(now: 8)
        let (released, timedOut) = unanswered.expire(now: 60)
        #expect(released.isEmpty && timedOut == [late.id] && unanswered.pending.eventCount == 0)
        // A hold longer than the timeout changes nothing: the deadline drops the flow.
        _ = unanswered.pending.add("slow", key: key, addressMatches: true, now: 100, timeout: 10, holdFor: 30,
                                   makeEvent: maker.make(key))
        #expect(unanswered.expire(now: 110).released.map(\.reason) == ["timeout"])
    }
}

/// An interpreter's answers are bound to its script (ScriptScope): an agent's covers the script
/// its event named, a person's the one it names, or all of them.
struct ScriptScopeTests {
    private static let aws = ScriptScope.script("/opt/homebrew/bin/aws")
    private static let other = ScriptScope.script("/tmp/upload.py")

    /// Homebrew's python, ad hoc signed, to sts.amazonaws.com from three scripts: the AWS CLI,
    /// another script and none at all (`python3 -c`).
    private func state() -> (AskState<String>, [ScriptScope: HookEvent]) {
        var ask = AskState<String>()
        let maker = EventMaker()
        var events: [ScriptScope: HookEvent] = [:]
        for (name, scope) in [("aws", Self.aws), ("other", Self.other), ("none", ScriptScope.script(nil))] {
            let key = PendingKey(identity: build, host: "sts.amazonaws.com", port: 443, scope: scope)
            if case .raised(let event) = ask.pending.add(name, key: key, addressMatches: true, now: 0, timeout: 10,
                                                         makeEvent: maker.make(key)) {
                events[scope] = event
            }
        }
        return (ask, events)
    }

    private func covered(_ table: ApprovalTable, _ scope: ScriptScope, now: TimeInterval = 2) -> Bool {
        table.covers(build, host: "sts.amazonaws.com", scope: scope, now: now)
    }

    @Test func eachScriptWaitsOnItsOwnEvent() {
        let (ask, events) = state()
        #expect(events.count == 3 && ask.pending.eventCount == 3)
    }

    @Test func anAgentsApprovalCoversOnlyItsEventsScript() throws {
        var (ask, events) = state()
        let token = try #require(events[Self.aws]?.token)
        let outcome = ask.answer(request(.approve, build, host: "sts.amazonaws.com", seconds: 3600, token: token), now: 1)
        #expect(outcome.reply.status == .done)
        #expect(outcome.reply.message.contains(" → sts.amazonaws.com (running /opt/homebrew/bin/aws) for "))
        #expect(outcome.released.map(\.flow) == ["aws"] && outcome.released.allSatisfy(\.allow))
        #expect(covered(ask.approvals, Self.aws))
        // The same python running another script, or none, still asks; so does code that is no interpreter.
        #expect(!covered(ask.approvals, Self.other) && !covered(ask.approvals, .script(nil)) && !covered(ask.approvals, .any))
        #expect(ask.pending.eventCount == 2)
        #expect(ask.approvals.summaries(now: 2)
            == [ApprovalSummary(app: AppReference(build), host: "sts.amazonaws.com", secondsLeft: 3599, scope: Self.aws)])
    }

    @Test func aPersonsAnswerWithNoScriptCoversThemAll() {
        var (ask, _) = state()
        let outcome = ask.answer(request(.approve, build, host: "sts.amazonaws.com", seconds: 600), now: 1)
        #expect(Set(outcome.released.map(\.flow)) == ["aws", "other", "none"])
        #expect(!outcome.reply.message.contains("running"))
        for scope in [Self.aws, Self.other, .script(nil), .any] { #expect(covered(ask.approvals, scope)) }
    }

    @Test func aPersonsAnswerCanNameOneScript() {
        var (ask, _) = state()
        let approve = AnswerRequest(kind: .approve, app: build, host: "sts.amazonaws.com", seconds: 600, token: nil,
                                    script: "/tmp/upload.py")
        let outcome = ask.answer(approve, now: 1)
        #expect(outcome.released.map(\.flow) == ["other"])
        #expect(outcome.reply.message.contains("(running /tmp/upload.py)"))
        #expect(covered(ask.approvals, Self.other) && !covered(ask.approvals, Self.aws))
    }

    @Test func aDenialOfOneScriptLeavesTheOthersAsking() throws {
        var (ask, events) = state()
        let deny = request(.deny, build, host: "sts.amazonaws.com", token: try #require(events[.script(nil)]?.token))
        let outcome = ask.answer(deny, now: 1)
        #expect(outcome.released.map(\.flow) == ["none"] && outcome.reply.message.contains("(with no script)"))
        #expect(covered(ask.denials, .script(nil)) && !covered(ask.denials, Self.aws) && !covered(ask.denials, .any))
        #expect(ask.denials.summaries(now: 2).first?.noScript == true)
        // An agent's approval of another script leaves that denial alone.
        let approve = ask.answer(request(.approve, build, host: "sts.amazonaws.com", token: try #require(events[Self.aws]?.token)),
                                 now: 2)
        #expect(!approve.reply.message.contains("replacing its denial") && covered(ask.denials, .script(nil), now: 3))
        // A person's answer for every script takes back the answers of each.
        let all = ask.answer(request(.deny, build, host: "sts.amazonaws.com"), now: 3)
        #expect(all.reply.message.contains("removing its approval"))
        #expect(!covered(ask.approvals, Self.aws, now: 4) && covered(ask.denials, Self.other, now: 4))
        #expect(ask.denials.count == 1)
        let back = ask.answer(request(.approve, build, host: "sts.amazonaws.com"), now: 4)
        #expect(back.reply.message.contains("replacing its denial") && ask.denials.count == 0)
    }

    @Test func aPersonsApprovalOfOneScriptOutranksADenialOfAll() {
        var ask = AskState<String>()
        _ = ask.answer(request(.deny, build, host: "sts.amazonaws.com"), now: 0)
        _ = ask.answer(AnswerRequest(kind: .approve, app: build, host: "sts.amazonaws.com", seconds: 600, token: nil,
                                     script: "/opt/homebrew/bin/aws"), now: 1)
        // FilterPolicy checks approvals first: that script goes through, the others stay denied.
        #expect(covered(ask.approvals, Self.aws) && covered(ask.denials, Self.aws))
        #expect(!covered(ask.approvals, Self.other) && covered(ask.denials, Self.other))
    }

    @Test func onlyAnInterpreterHasAScriptScope() {
        var read = 0
        let script = { () -> String? in read += 1; return "/tmp/x.py" }
        #expect(ScriptScope.of(executablePath: "/usr/bin/curl", script: script) == .any)
        #expect(ScriptScope.of(executablePath: nil, script: script) == .any)
        #expect(read == 0)
        #expect(ScriptScope.of(executablePath: "/opt/homebrew/Cellar/python@3.14/3.14.0/bin/python3.14", script: script)
            == .script("/tmp/x.py"))
        #expect(ScriptScope.of(executablePath: "/opt/homebrew/bin/node", script: { nil }) == .script(nil))
    }

    @Test func aPersonCanNameOnlyAFullPathOrAModule() {
        #expect(ScriptScope.canName("/opt/homebrew/bin/aws") && ScriptScope.canName("-m pip"))
        #expect(!ScriptScope.canName("aws") && !ScriptScope.canName("") && !ScriptScope.canName("/tmp/a\u{7}b"))
        #expect(!ScriptScope.canName("/" + String(repeating: "a", count: HookEvent.maximumPathBytes)))
    }
}
