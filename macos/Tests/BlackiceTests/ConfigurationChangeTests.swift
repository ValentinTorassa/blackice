import Foundation
import Testing
@testable import BlackiceCore

// A configuration change while ask mode has connections paused. The extension installs the new
// snapshot, then drops every paused flow and cancels its events (`configuration_changed`). A flow
// callback that read the old snapshot can reach the pending list after that drop, and an answer
// taken just before the change can be applied after it: FilterPolicy.isCurrent and
// FilterPolicy.current keep either from letting a connection through under the new configuration.
// The steps the extension takes between them are replayed here with the same types.

private let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))

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
}
