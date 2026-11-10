import Foundation
import Testing
@testable import BlackiceCore

// The UDP destinations a run let through on a host's name, kept for the next run (VerifiedFlows).
// Rule lines: 3 lets the VPN client reach *.vpn.example.com, 8 lets ssh reach a range and a name,
// 12 lets the tunnel reach anything.
private let rules = """
mode = "block-all"

[[allow]]
app = "com.example.vpn"
team = "ABCDE12345"
hosts = ["*.vpn.example.com"]

[[allow]]
app = "com.apple.ssh"
hosts = ["100.64.0.0/10", "*.ts.net"]

[[allow]]
app = "com.example.tunnel"
team = "ABCDE12345"
hosts = ["*"]

"""

private func snapshot(_ mode: Mode) throws -> ProviderConfiguration {
    try ProviderConfiguration(generation: 7, mode: mode, configText: rules)
}

private func signed(_ id: String, _ team: String?) -> IdentityResolution {
    .verified(SigningIdentity(signingID: id, teamID: team))
}

private let vpn = signed("com.example.vpn", "ABCDE12345")
private let ssh = signed("com.apple.ssh", nil)
private let tunnel = signed("com.example.tunnel", "ABCDE12345")
private let probe = signed("com.valentorassa.blackice.probe", "ABCDE12345")
private let endpoint = "edge.vpn.example.com"
private let there = "203.0.113.7"

private func flow(_ identity: IdentityResolution, host: String? = endpoint, address: String? = there, port: UInt16? = 443,
                  tcp: Bool = false, direction: FlowDirection = .outbound, names: Set<String> = []) -> FlowFacts {
    FlowFacts(direction: direction, identity: identity, internetSocket: true, tcp: tcp, hostname: host, port: port,
              remoteAddress: address.flatMap(IPAddress.init), dnsNames: names)
}

private func destination(_ host: String, _ address: String, _ port: UInt16 = 443) -> VerifiedFlows.Destination {
    VerifiedFlows.Destination(host: host, address: IPAddress(address)!, port: port)
}

private func app(_ identity: IdentityResolution) -> AppIdentity { identity.appIdentity! }

/// No lookup has answered: a host whose address no DNS answer gave waits for one.
private var unresolved: PolicyContext { PolicyContext(approved: { _, _ in false }, address: { _, _ in .unknown }) }

struct VerifiedFlowsTests {
    // 10 November 2026: an upgrade paused the AWS VPN Client's flow for a lookup that had to go
    // through that flow's own tunnel; 30 s later it was dropped, and DNS went with the tunnel.
    @Test func aRestartedFilterDoesNotLookUpWhatTheLastRunChecked() throws {
        let ask = try snapshot(.ask)
        // The last run: the VPN client's UDP flow, let through by rule 3 once the address checked out.
        let checked = PolicyContext(approved: { _, _ in false }, address: { _, _ in .match })
        let first = FilterPolicy.decide(flow(vpn), snapshot: ask, context: checked)
        #expect(first == .allow(reason: "rule_line_3"))
        var lastRun = VerifiedFlows()
        let kept = try #require(FilterPolicy.verified(flow(vpn), first, snapshot: ask))
        lastRun.record(app: kept.app, kept.destination, timeOfDay: 1000)
        // The next run reads what it saved.
        let file = try #require(lastRun.saved())
        let restored = try #require(VerifiedFlows(saved: file, timeOfDay: 1500))
        // Without it, the same flow waits for a lookup, which for a VPN's own flow never answers.
        #expect(FilterPolicy.decide(flow(vpn), snapshot: ask, context: unresolved) == .resolveHost(endpoint))
        // With it, the flow carries the name the last run checked, and passes with no lookup.
        let names = restored.names(app: app(vpn), address: IPAddress(there)!, port: 443)
        #expect(names == [endpoint])
        #expect(FilterPolicy.decide(flow(vpn, names: names), snapshot: ask, context: unresolved) == .allow(reason: "rule_line_3"))
        // A socket connected with no host name is named the same way.
        #expect(FilterPolicy.decide(flow(vpn, host: nil, names: names), snapshot: ask, context: unresolved)
                == .allow(reason: "rule_line_3;dns_name"))
        // The rule still decides: another host for the same address is looked up, and so is this
        // host at another address or port, or for another app.
        #expect(FilterPolicy.decide(flow(vpn, host: "other.vpn.example.com", names: names), snapshot: ask, context: unresolved)
                == .resolveHost("other.vpn.example.com"))
        #expect(restored.names(app: app(vpn), address: IPAddress("203.0.113.8")!, port: 443).isEmpty)
        #expect(restored.names(app: app(vpn), address: IPAddress(there)!, port: 1194).isEmpty)
        #expect(restored.names(app: app(probe), address: IPAddress(there)!, port: 443).isEmpty)
        // A name the rules no longer cover gets the flow nothing: ask mode asks about it.
        let other = FilterPolicy.decide(flow(probe, names: names), snapshot: ask, context: unresolved)
        #expect(other == .ask(reason: "no_rule", addressMatches: true))
    }

    // A flow that passes on a name the last run supplied was not checked by this run: its
    // destination keeps the date of the check, so the 30 days are not renewed by each restart.
    @Test func aRestoredNameKeepsTheDateOfItsCheck() throws {
        let ask = try snapshot(.ask)
        let day = 86_400.0
        var run = VerifiedFlows()
        run.record(app: app(vpn), destination(endpoint, there), timeOfDay: 0)
        // Restarts on days 10, 20 and 29, the app sending within the window each time, and no
        // lookup or DNS answer in between.
        for restart in [10.0, 20.0, 29.0] {
            let file = try #require(run.saved())
            let restored = try #require(VerifiedFlows(saved: file, timeOfDay: restart * day))
            let facts = restored.facts(app: app(vpn), address: IPAddress(there)!, port: 443, names: [], aliases: [])
            #expect(facts.names == [endpoint] && facts.restored == [endpoint: 0])
            let resumed = FlowFacts(direction: .outbound, identity: vpn, internetSocket: true, tcp: false, hostname: endpoint,
                                    port: 443, remoteAddress: IPAddress(there), dnsNames: facts.names, dnsAliases: facts.aliases,
                                    restored: facts.restored)
            let verdict = FilterPolicy.decide(resumed, snapshot: ask, context: unresolved)
            #expect(verdict == .allow(reason: "rule_line_3"))
            let kept = try #require(FilterPolicy.verified(resumed, verdict, snapshot: ask))
            #expect(kept.checkedAt == 0)
            run = VerifiedFlows()
            run.carry(app: kept.app, kept.destination, checkedAt: kept.checkedAt ?? -1)
            #expect(run.checked(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint: 0])
        }
        // 31 days after the check it is not read back, whatever restarts came between.
        let lastFile = try #require(run.saved())
        let late = try #require(VerifiedFlows(saved: lastFile, timeOfDay: 31 * day))
        #expect(late.count == 0)
        // A flow this run checked itself is dated now, and a carried date never replaces that.
        let fresh = try #require(FilterPolicy.verified(flow(vpn), .allow(reason: "rule_line_3"), snapshot: ask))
        #expect(fresh.checkedAt == nil)
        var both = VerifiedFlows()
        both.record(app: fresh.app, fresh.destination, timeOfDay: 29 * day)
        both.carry(app: fresh.app, fresh.destination, checkedAt: 0)
        #expect(both.checked(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint: 29 * day])
        // The other way round, the check replaces the carried date.
        var carried = VerifiedFlows()
        carried.carry(app: fresh.app, fresh.destination, checkedAt: 0)
        carried.record(app: fresh.app, fresh.destination, timeOfDay: 29 * day)
        #expect(carried.checked(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint: 29 * day])
    }

    // A restored host must not take the name away from a flow that DNS answers of this run name:
    // a flow with no host name is decided on exactly one name.
    @Test func aRestoredHostDoesNotUnnameAFlowThatDNSNames() throws {
        let ask = try snapshot(.ask)
        var lastRun = VerifiedFlows()
        lastRun.record(app: app(vpn), destination(endpoint, there), timeOfDay: 1000)
        let other = "cdn.vpn.example.com"
        func facts(names: Set<String>, aliases: Set<String> = [], host: String?) -> FlowFacts {
            let added = lastRun.facts(app: app(vpn), address: IPAddress(there)!, port: 443, names: names, aliases: aliases)
            return FlowFacts(direction: .outbound, identity: vpn, internetSocket: true, tcp: false, hostname: host, port: 443,
                             remoteAddress: IPAddress(there), dnsNames: added.names, dnsAliases: added.aliases, restored: added.restored)
        }
        // DNS gave the address another name in this run: a flow with no host name is decided on
        // that one, as before, and the restored host only passes the check for a flow that names it.
        let nameless = facts(names: [other], host: nil)
        #expect(nameless.dnsNames == [other] && nameless.dnsAliases == [endpoint] && nameless.restored == [endpoint: 1000])
        #expect(FilterPolicy.decide(nameless, snapshot: ask, context: unresolved) == .allow(reason: "rule_line_3;dns_name"))
        #expect(FilterPolicy.verified(nameless, .allow(reason: "rule_line_3;dns_name"), snapshot: ask)?.checkedAt == nil)
        let named = facts(names: [other], host: endpoint)
        #expect(FilterPolicy.decide(named, snapshot: ask, context: unresolved) == .allow(reason: "rule_line_3"))
        #expect(FilterPolicy.verified(named, .allow(reason: "rule_line_3"), snapshot: ask)?.checkedAt == 1000)
        // DNS gave it no name: the restored host names the flow.
        let alone = facts(names: [], host: nil)
        #expect(alone.dnsNames == [endpoint] && alone.dnsAliases.isEmpty)
        #expect(FilterPolicy.decide(alone, snapshot: ask, context: unresolved) == .allow(reason: "rule_line_3;dns_name"))
        // DNS gave the same host, as a name or as an alias: nothing is restored, and the flow
        // counts as checked by this run.
        #expect(facts(names: [endpoint], host: endpoint).restored.isEmpty)
        let aliased = facts(names: [other], aliases: [endpoint], host: endpoint)
        #expect(aliased.restored.isEmpty && aliased.dnsAliases == [endpoint])
        // Another app, address or port gets nothing.
        let none = lastRun.facts(app: app(probe), address: IPAddress(there)!, port: 443, names: [other], aliases: [])
        #expect(none.names == [other] && none.aliases.isEmpty && none.restored.isEmpty)
    }

    @Test func onlyAUDPFlowLetThroughOnACheckedNameIsKept() throws {
        let ask = try snapshot(.ask), block = try snapshot(.blockAll), all = try snapshot(.acceptAll)
        let kept = FilterPolicy.verified(flow(vpn), .allow(reason: "rule_line_3"), snapshot: ask)
        #expect(kept?.app == app(vpn) && kept?.destination == destination(endpoint, there))
        #expect(FilterPolicy.verified(flow(vpn), .allow(reason: "rule_line_3"), snapshot: block) != nil)
        // The name a DNS answer gave the address, for a flow with no host name.
        #expect(FilterPolicy.verified(flow(vpn, host: nil, names: [endpoint]), .allow(reason: "rule_line_3;dns_name"), snapshot: ask)?
            .destination == destination(endpoint, there))
        // An approval, at once or once the agent answered.
        #expect(FilterPolicy.verified(flow(probe), .allow(reason: "approval"), snapshot: ask) != nil)
        #expect(FilterPolicy.verified(flow(probe), .allow(reason: "approved"), snapshot: ask) != nil)
        // Not kept: TCP, a drop, accept-all, an inbound flow, a flow with no port or no address.
        #expect(FilterPolicy.verified(flow(vpn, tcp: true), .allow(reason: "rule_line_3"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn), .drop(reason: "address_mismatch"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn), .allow(reason: "accept_all"), snapshot: all) == nil)
        #expect(FilterPolicy.verified(flow(vpn), .allow(reason: "rule_line_3"), snapshot: all) == nil)
        #expect(FilterPolicy.verified(flow(vpn), .allow(reason: "rule_line_3"), snapshot: nil) == nil)
        #expect(FilterPolicy.verified(flow(vpn, direction: .inbound), .allow(reason: "inbound_not_filtered"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn, port: nil), .allow(reason: "rule_line_3"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn, address: nil), .allow(reason: "rule_line_3"), snapshot: ask) == nil)
        // Not kept: no name at all, several names, loopback, an address asked about by itself.
        #expect(FilterPolicy.verified(flow(vpn, host: nil), .allow(reason: "approval;address"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn, host: nil, names: ["a.example.com", "b.example.com"]),
                                      .allow(reason: "approved"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn, address: "127.0.0.1"), .allow(reason: "loopback"), snapshot: ask) == nil)
        // Not kept: a link-local address, with or without its interface. A saved one has none,
        // and a file with such an entry is refused whole.
        #expect(FilterPolicy.verified(flow(vpn, address: "fe80::1"), .allow(reason: "rule_line_3"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(vpn, address: "fe80::1%1"), .allow(reason: "rule_line_3"), snapshot: ask) == nil)
        // Not kept: a flow that a `*` rule or an address rule covers, whose name nothing checked.
        #expect(FilterPolicy.verified(flow(tunnel), .allow(reason: "rule_line_12"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(ssh, host: "host.ts.net", address: "100.66.32.75", port: 22),
                                      .allow(reason: "rule_line_8;address"), snapshot: ask) == nil)
        #expect(FilterPolicy.verified(flow(ssh, host: "host.ts.net", address: "100.66.32.75", port: 22),
                                      .allow(reason: "rule_line_8"), snapshot: ask) == nil)
        // A name of the same rule at an address outside its ranges was checked, and is kept.
        #expect(FilterPolicy.verified(flow(ssh, host: "host.ts.net", address: there, port: 22),
                                      .allow(reason: "rule_line_8"), snapshot: ask) != nil)
    }

    @Test func keepsTheLatestOfEachAppAndStaysBounded() {
        var flows = VerifiedFlows()
        #expect(flows.count == 0 && flows.revision == 0)
        for index in 0..<VerifiedFlows.limitPerApp {
            flows.record(app: app(vpn), destination(endpoint, "203.0.113.\(index + 1)"), timeOfDay: Double(index))
        }
        #expect(flows.count == VerifiedFlows.limitPerApp && flows.revision == VerifiedFlows.limitPerApp)
        // One more takes the place of the one let through longest ago.
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 100)
        #expect(flows.count == VerifiedFlows.limitPerApp)
        #expect(flows.names(app: app(vpn), address: IPAddress("203.0.113.1")!, port: 443).isEmpty)
        #expect(flows.names(app: app(vpn), address: IPAddress("203.0.113.2")!, port: 443) == [endpoint])
        #expect(flows.names(app: app(vpn), address: IPAddress("203.0.113.200")!, port: 443) == [endpoint])
        // The same destination again is not something new to save, until an hour has gone by since
        // the time it has: a flow let through every few seconds is dated again once an hour.
        let revision = flows.revision
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 200)
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 100 + 3599)
        #expect(flows.revision == revision && flows.count == VerifiedFlows.limitPerApp)
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 100 + 3600)
        #expect(flows.revision == revision + 1)
        // A clock set back by less than that changes nothing. Set back by more, the destination
        // takes the new time: one written while the clock was ahead does not stay ahead.
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 3700 - 3599)
        #expect(flows.revision == revision + 1)
        flows.record(app: app(vpn), destination(endpoint, "203.0.113.200"), timeOfDay: 50)
        #expect(flows.revision == revision + 2)
        #expect(flows.checked(app: app(vpn), address: IPAddress("203.0.113.200")!, port: 443) == [endpoint: 50])
        // Two hosts at one address and port are both that destination's names; another app has none.
        flows.record(app: app(vpn), destination("b.vpn.example.com", "203.0.113.200"), timeOfDay: 4000)
        #expect(flows.names(app: app(vpn), address: IPAddress("203.0.113.200")!, port: 443) == [endpoint, "b.vpn.example.com"])
        #expect(flows.names(app: app(probe), address: IPAddress("203.0.113.200")!, port: 443).isEmpty)
        // An IPv4-mapped address is the same address.
        #expect(flows.names(app: app(vpn), address: IPAddress("::ffff:203.0.113.200")!, port: 443).count == 2)

        // One app more than the limit: the app whose latest is oldest goes.
        var many = VerifiedFlows()
        for index in 0..<VerifiedFlows.appLimit {
            many.record(app: .signed(SigningIdentity(signingID: "com.example.app\(index)", teamID: "ABCDE12345")),
                        destination(endpoint, there), timeOfDay: Double(index + 10))
        }
        many.record(app: app(vpn), destination(endpoint, there), timeOfDay: 5000)
        #expect(many.count == VerifiedFlows.appLimit)
        let first = AppIdentity.signed(SigningIdentity(signingID: "com.example.app0", teamID: "ABCDE12345"))
        let second = AppIdentity.signed(SigningIdentity(signingID: "com.example.app1", teamID: "ABCDE12345"))
        #expect(many.names(app: first, address: IPAddress(there)!, port: 443).isEmpty)
        #expect(many.names(app: second, address: IPAddress(there)!, port: 443) == [endpoint])
        #expect(many.names(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint])
    }

    @Test func savesAndReadsBack() throws {
        var flows = VerifiedFlows()
        flows.record(app: app(vpn), destination(endpoint, there), timeOfDay: 1000)
        flows.record(app: app(vpn), destination(endpoint, "2001:db8::7", 1194), timeOfDay: 2000)
        flows.record(app: .cdhash(testCDHash), destination("time.example.org", "198.51.100.4", 123), timeOfDay: 3000)
        let data = try #require(flows.saved())
        let restored = try #require(VerifiedFlows(saved: data, timeOfDay: 4000))
        #expect(restored.count == 3 && restored.revision == 0)
        #expect(restored.names(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint])
        #expect(restored.names(app: app(vpn), address: IPAddress("2001:db8::7")!, port: 1194) == [endpoint])
        #expect(restored.names(app: .cdhash(testCDHash), address: IPAddress("198.51.100.4")!, port: 123) == ["time.example.org"])
        // Saved again, it is the same file.
        #expect(restored.saved() == data)
        // A destination older than 30 days is not read back, nor one dated after now.
        let later = try #require(VerifiedFlows(saved: data, timeOfDay: 1000 + VerifiedFlows.maximumAge + 1))
        #expect(later.count == 2 && later.names(app: app(vpn), address: IPAddress(there)!, port: 443).isEmpty)
        let earlier = try #require(VerifiedFlows(saved: data, timeOfDay: 2500))
        #expect(earlier.count == 2 && earlier.names(app: .cdhash(testCDHash), address: IPAddress("198.51.100.4")!, port: 123).isEmpty)
        // What a merge adds: this run's own, and the last run's that it has not seen again.
        var thisRun = VerifiedFlows()
        thisRun.record(app: app(vpn), destination(endpoint, there), timeOfDay: 5000)
        var merged = restored
        merged.merge(thisRun)
        #expect(merged.count == 3)
        let both = try #require(merged.saved())
        let again = try #require(VerifiedFlows(saved: both, timeOfDay: 5000 + VerifiedFlows.maximumAge - 1000))
        #expect(again.count == 1 && again.names(app: app(vpn), address: IPAddress(there)!, port: 443) == [endpoint])
    }

    @Test func refusesAFileItDidNotWrite() throws {
        func file(_ flows: String, version: Int = 1) -> Data {
            Data(#"{"flows":[\#(flows)],"version":\#(version)}"#.utf8)
        }
        let good = #"{"app":{"signing_id":"com.example.vpn","team_id":"ABCDE12345"},"at":1000,"host":"edge.vpn.example.com","ip":"203.0.113.7","port":443}"#
        #expect(VerifiedFlows(saved: file(good), timeOfDay: 2000)?.count == 1)
        #expect(VerifiedFlows(saved: file(""), timeOfDay: 2000)?.count == 0)
        #expect(VerifiedFlows(saved: file(good, version: 2), timeOfDay: 2000) == nil)
        #expect(VerifiedFlows(saved: Data("not json".utf8), timeOfDay: 2000) == nil)
        // One entry that is not valid refuses the file: a host that is not normalized, an address
        // written another way or with an interface, port 0, an app with both forms or neither.
        for bad in [good.replacingOccurrences(of: "edge.vpn.example.com", with: "Edge.VPN.example.com"),
                    good.replacingOccurrences(of: "edge.vpn.example.com", with: "203.0.113.9"),
                    good.replacingOccurrences(of: "203.0.113.7", with: "203.000.113.7"),
                    good.replacingOccurrences(of: "203.0.113.7", with: "fe80::1%4"),
                    good.replacingOccurrences(of: "203.0.113.7", with: "fe80::1"),
                    good.replacingOccurrences(of: "\"port\":443", with: "\"port\":0"),
                    good.replacingOccurrences(of: "\"team_id\":\"ABCDE12345\"", with: "\"team_id\":\"ABCDE12345\",\"cdhash\":\"\(testCDHash)\""),
                    good.replacingOccurrences(of: "\"signing_id\":\"com.example.vpn\",", with: "")] {
            #expect(VerifiedFlows(saved: file(good + "," + bad), timeOfDay: 2000) == nil, "\(bad)")
        }
        // More entries than the limits allow.
        let entries = (0...(VerifiedFlows.limitPerApp * VerifiedFlows.appLimit)).map { _ in good }.joined(separator: ",")
        #expect(VerifiedFlows(saved: file(entries), timeOfDay: 2000) == nil)
    }
}
