import Foundation
import Testing
@testable import BlackiceCore

// A configuration change while ask mode has connections paused. The extension installs the new
// snapshot, then ends every paused and held flow and cancels its events: the new configuration
// decides each one again (FilterPolicy.afterChange), lets go what it allows outright and drops the
// rest (`configuration_changed`). A flow callback that read the old snapshot can reach the pending
// list after that, and an answer taken just before the change can be applied after it:
// FilterPolicy.isCurrent and FilterPolicy.current keep either from letting a connection through
// under the new configuration. The steps the extension takes between them are replayed here with
// the same types.

private let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
private let agent = IdentityResolution.verified(SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345"))

private func waiting(_ host: String?, identity: IdentityResolution = agent, port: UInt16 = 443,
                     address: String = "203.0.113.7") -> FlowFacts {
    FlowFacts(direction: .outbound, identity: identity, internetSocket: true, tcp: true, hostname: host, port: port,
              remoteAddress: IPAddress(address))
}

private func answers(_ check: AddressCheck) -> (String, IPAddress?) -> AddressCheck { { _, _ in check } }

/// A paused flow as the extension keeps it: with the generation it was decided under.
private struct Waiting {
    let name: String
    let generation: UInt64
}

private func makeEvent(_ key: PendingKey) -> (TimeInterval) throws -> HookEvent {
    { seconds in
        try HookEvent.connection(app: HookEvent.App(key.identity, path: nil), host: key.host, ip: "203.0.113.7",
                                 port: key.port, deadline: Date().addingTimeInterval(seconds))
    }
}

struct ConfigurationChangeTests {
    @Test func aFlowDecidedBeforeAChangeDoesNotWaitAfterIt() throws {
        let store = ProviderSnapshotStore()
        try store.install(try policySnapshot(.ask, generation: 7))
        // A flow's callback reads the snapshot and decides to ask about its host...
        let read = try #require(store.read())
        let facts = FlowFacts(direction: .outbound, identity: .verified(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345")),
                              internetSocket: true, tcp: true, hostname: "example.org", port: 443,
                              remoteAddress: IPAddress("203.0.113.7"))
        let context = PolicyContext(approved: { _, _ in false }, address: { _, _ in .match })
        #expect(FilterPolicy.decide(facts, snapshot: read, context: context) == .ask(reason: "no_rule", addressMatches: true))
        // ...while `blackice mode block-all` installs the next generation and drops what is paused.
        try store.install(try read.with(mode: .blockAll))
        var ask = AskState<Waiting>()
        #expect(ask.pending.removeAll().isEmpty)
        // The callback reaches the pending list only now, with the snapshot it read: it must not
        // raise an event, which a hook could approve under block-all.
        #expect(!FilterPolicy.isCurrent(read.generation, installed: store.read()))
        #expect(ask.pending.eventCount == 0)
        // A flow decided with the installed configuration waits as before; with none, nothing does.
        #expect(FilterPolicy.isCurrent(8, installed: store.read()))
        store.clear()
        #expect(!FilterPolicy.isCurrent(8, installed: store.read()))
    }

    @Test func anAnswerTakenBeforeAChangeLetsNothingThroughAfterIt() throws {
        let asked = try policySnapshot(.ask, generation: 7)
        var ask = AskState<Waiting>()
        let key = PendingKey(identity: tool, host: "example.org", port: 443)
        guard case .raised(let event) = ask.pending.add(Waiting(name: "matching", generation: 7), key: key,
                                                        addressMatches: true, now: 0, timeout: 60,
                                                        makeEvent: makeEvent(key)) else {
            Issue.record("the first flow raises an event")
            return
        }
        let other = PendingKey(identity: tool, host: "example.org", port: 8443)
        _ = ask.pending.add(Waiting(name: "elsewhere", generation: 7), key: other, addressMatches: false, now: 0,
                            timeout: 60, makeEvent: makeEvent(other))
        // The hook approves with the event's token, and the flows come off the pending list...
        let outcome = ask.answer(AnswerRequest(kind: .approve, app: tool, host: "example.org", seconds: 600,
                                               token: event.token), now: 1)
        #expect(outcome.reply.status == .done && outcome.released.count == 2)
        // ...then the mode changes before they are resumed: none is let through.
        let blocked = try asked.with(mode: .blockAll)
        let applied = FilterPolicy.current(outcome.released, installed: blocked, generation: \.generation)
        #expect(applied.allSatisfy { !$0.allow })
        #expect(applied.map(\.reason).sorted() == ["approved;address_mismatch", "configuration_changed"])
        #expect(FilterPolicy.current(outcome.released, installed: nil, generation: \.generation).allSatisfy { !$0.allow })
        // Under the configuration they were decided with, the answer applies as given.
        let unchanged = FilterPolicy.current(outcome.released, installed: asked, generation: \.generation)
        #expect(unchanged.map(\.allow) == outcome.released.map(\.allow))
        #expect(unchanged.map(\.reason) == outcome.released.map(\.reason))
        // A flow of the installed generation passes; a drop stays the drop it was.
        let current = [Release(flow: Waiting(name: "new", generation: 8), allow: true, reason: "approved", eventID: event.id),
                       Release(flow: Waiting(name: "old", generation: 7), allow: false, reason: "denied", eventID: event.id)]
        let kept = FilterPolicy.current(current, installed: blocked, generation: \.generation)
        #expect(kept.map(\.allow) == [true, false] && kept.map(\.reason) == ["approved", "denied"])
    }

    /// Switching from ask mode to accept-all dropped every connection that waited (20 at once on
    /// the Mac). Now what the new configuration allows outright goes on.
    @Test func whatTheNewConfigurationAllowsOutrightGoesOn() throws {
        let acceptAll = try policySnapshot(.acceptAll, generation: 8)
        let accepted = FlowVerdict.allow(reason: "accept_all;configuration_changed")
        // Accept-all lets every waiting flow go: paused before or after its hello, held for it, or
        // waiting for a lookup, whatever the cache knows of its host.
        for check in [AddressCheck.match, .mismatch, .unknown] {
            #expect(FilterPolicy.afterChange(waiting("other.example.com"), serverName: nil, echPresent: false,
                                             snapshot: acceptAll, address: answers(check)) == accepted)
            #expect(FilterPolicy.afterChange(waiting(nil), serverName: "other.example.com", echPresent: true,
                                             snapshot: acceptAll, address: answers(check)) == accepted)
            #expect(FilterPolicy.afterChange(waiting(nil, identity: .adHoc(cdhash: testCDHash), port: 22), serverName: nil,
                                             echPresent: false, snapshot: acceptAll, address: answers(check)) == accepted)
        }
        // A rule of the new configuration: off port 443 once the address checks out, on it once the
        // hello was read. Before the hello it would be read first, so the flow is dropped as before;
        // nothing is looked up.
        let blockAll = try policySnapshot(.blockAll, generation: 8)
        let dropped = FlowVerdict.drop(reason: "configuration_changed")
        #expect(FilterPolicy.afterChange(waiting("api.example.com", port: 8443), serverName: nil, echPresent: false,
                                         snapshot: blockAll, address: answers(.match))
            == .allow(reason: "rule_line_3;configuration_changed"))
        #expect(FilterPolicy.afterChange(waiting("api.example.com"), serverName: "api.example.com", echPresent: false,
                                         snapshot: blockAll, address: answers(.match))
            == .allow(reason: "rule_line_3;server_name;configuration_changed"))
        #expect(FilterPolicy.afterChange(waiting("api.example.com"), serverName: nil, echPresent: false,
                                         snapshot: blockAll, address: answers(.match)) == dropped)
        for check in [AddressCheck.unknown, .mismatch] {
            #expect(FilterPolicy.afterChange(waiting("api.example.com", port: 8443), serverName: nil, echPresent: false,
                                             snapshot: blockAll, address: answers(check)) == dropped)
        }
        #expect(FilterPolicy.afterChange(waiting("other.example.com", port: 8443), serverName: nil, echPresent: false,
                                         snapshot: blockAll, address: answers(.match)) == dropped)
        // The Apple services table and loopback count like a rule.
        let cloudd = IdentityResolution.verified(SigningIdentity(signingID: "com.apple.cloudd", teamID: nil))
        #expect(FilterPolicy.afterChange(waiting("p01-ckdatabase.icloud.com", identity: cloudd, port: 8443), serverName: nil,
                                         echPresent: false, snapshot: blockAll, address: answers(.match))
            == .allow(reason: "apple_service;configuration_changed"))
        #expect(FilterPolicy.afterChange(waiting("other.example.com", port: 8443, address: "127.0.0.1"), serverName: nil,
                                         echPresent: false, snapshot: blockAll, address: answers(.unknown))
            == .allow(reason: "loopback;configuration_changed"))
        // With nothing installed, nothing goes on.
        #expect(FilterPolicy.afterChange(waiting("other.example.com"), serverName: nil, echPresent: false,
                                         snapshot: nil, address: answers(.match)) == dropped)
    }

    /// Ask mode again, under a new generation: what it would ask about is dropped as before, and an
    /// approval from the old configuration does not let it through.
    @Test func anApprovalFromTheOldConfigurationDoesNotCarryOver() throws {
        let ask = try policySnapshot(.ask, generation: 8)
        var state = AskState<Waiting>()
        let key = ApprovalKey(identity: try #require(agent.appIdentity), host: "other.example.com")
        state.approvals.add(key, seconds: 600, now: 0)
        let facts = waiting("other.example.com", port: 8443)
        // A new flow under the new configuration counts the approval...
        let approved = PolicyContext(approved: { state.approvals.covers(ApprovalKey(identity: $0, host: $1), now: 1) },
                                     address: answers(.match))
        #expect(FilterPolicy.decide(facts, snapshot: ask, context: approved) == .allow(reason: "approval"))
        // ...but a flow that waited under the old one is decided with none, and dropped.
        #expect(FilterPolicy.afterChange(facts, serverName: nil, echPresent: false, snapshot: ask, address: answers(.match))
            == .drop(reason: "configuration_changed"))
        // A rule in the new configuration still lets a waiting flow go in ask mode.
        #expect(FilterPolicy.afterChange(waiting("api.example.com", port: 8443), serverName: nil, echPresent: false,
                                         snapshot: ask, address: answers(.match))
            == .allow(reason: "rule_line_3;configuration_changed"))
    }
}
