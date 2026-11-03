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
        #expect(revoke.reply.message.contains("its approval was removed"))
        #expect(!ask.approvals.covers(ApprovalKey(identity: tool, host: "other.example.com"), now: 4))
    }

    @Test func aPersonMayApproveWithoutAnEvent() {
        var ask = AskState<String>()
        let outcome = ask.answer(request(.approve, build, host: "example.org", seconds: 60), now: 0)
        #expect(outcome.reply.status == .done && outcome.released.isEmpty)
        #expect(outcome.reply.message.contains("no connection was waiting"))
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
}
