import Foundation
import Testing
@testable import BlackiceCore

// The filter's decisions for flows named by the system resolver's answers (FlowFacts.dnsNames),
// with the rules of FilterPolicyTests: line 3 lets the agent reach api.example.com, line 8 lets
// the system curl reach pypi.org.

private func signed(_ id: String, _ team: String?) -> IdentityResolution {
    .verified(SigningIdentity(signingID: id, teamID: team))
}

private let agent = signed("com.example.agent", "ABCDE12345")
private let curl = signed("com.apple.curl", nil)
private let probe = signed("com.valentorassa.blackice.probe", "ABCDE12345")
private let adHoc = IdentityResolution.adHoc(cdhash: testCDHash)
private let here = "203.0.113.7"

/// A flow the app opened with BSD sockets: an address and no host name, by default on 443.
private func bare(_ identity: IdentityResolution, _ names: Set<String>, port: UInt16 = 443, tcp: Bool = true,
                  host: String? = nil, address: String? = here) -> FlowFacts {
    FlowFacts(direction: .outbound, identity: identity, internetSocket: true, tcp: tcp, hostname: host, port: port,
              remoteAddress: address.flatMap(IPAddress.init), dnsNames: names)
}

/// Approvals, and resolver answers by host; a host without answers is not looked up yet.
private func context(approved: Set<ApprovalKey> = [], answers: [String: [String]] = [:]) -> PolicyContext {
    PolicyContext(
        approved: { approved.contains(ApprovalKey(identity: $0, host: $1)) },
        address: { host, address in
            guard let list = answers[host] else { return .unknown }
            return HostAddressCache.check(address, against: Set(list.compactMap(IPAddress.init)))
        })
}

private func key(_ identity: IdentityResolution, _ host: String) -> ApprovalKey {
    ApprovalKey(identity: identity.appIdentity!, host: host)
}

private func decide(_ facts: FlowFacts, _ mode: Mode, _ context: PolicyContext = context()) throws -> FlowVerdict {
    FilterPolicy.decide(facts, snapshot: try policySnapshot(mode), context: context)
}

private func decide(_ facts: FlowFacts, serverName: String, _ mode: Mode,
                    _ context: PolicyContext = context()) throws -> FlowVerdict {
    FilterPolicy.decide(facts, serverName: .serverName(serverName), snapshot: try policySnapshot(mode), context: context)
}

struct DNSNamePolicyTests {
    @Test func theAppleServicesTableCoversADNSName() throws {
        // A macOS service that connects by address is not asked about when the table covers the name.
        let cloudd = signed("com.apple.cloudd", nil)
        #expect(try decide(bare(cloudd, ["gateway.icloud.com"], port: 80), .ask) == .allow(reason: "apple_service;dns_name"))
        #expect(try decide(bare(cloudd, ["gateway.icloud.com"], port: 80), .blockAll) == .allow(reason: "apple_service;dns_name"))
        #expect(try decide(bare(cloudd, ["gateway.icloud.com"]), .ask) == .readServerName)
        // A server name the table also covers goes on to its address check; any other is dropped.
        #expect(try decide(bare(cloudd, ["gateway.icloud.com"]), serverName: "p1-content.icloud.com", .blockAll)
                == .resolveHost("p1-content.icloud.com"))
        #expect(try decide(bare(cloudd, ["gateway.icloud.com"]), serverName: "evil.example", .blockAll)
                == .drop(reason: "server_name_mismatch"))
        // Code with a Team ID that calls itself com.apple.cloudd gets nothing from the table.
        let impostor = signed("com.apple.cloudd", "ABCDE12345")
        #expect(try decide(bare(impostor, ["gateway.icloud.com"], port: 80), .blockAll) == .drop(reason: "no_rule"))
        #expect(try decide(bare(impostor, ["gateway.icloud.com"], port: 80), .ask) == .ask(reason: "no_rule", addressMatches: true))
    }

    @Test func aRuleCoversTheDNSName() throws {
        // No lookup: the name came with the address. Off the TLS port the flow passes at once.
        #expect(try decide(bare(curl, ["pypi.org"], port: 22), .blockAll) == .allow(reason: "rule_line_8;dns_name"))
        #expect(try decide(bare(curl, ["pypi.org"], port: 80, tcp: false), .blockAll) == .allow(reason: "rule_line_8;dns_name"))
        #expect(try decide(bare(agent, ["api.example.com"], port: 8443), .ask) == .allow(reason: "rule_line_3;dns_name"))
        // On the TLS port the ClientHello is still read.
        #expect(try decide(bare(curl, ["pypi.org"]), .blockAll) == .readServerName)
        #expect(try decide(bare(agent, ["api.example.com"]), .ask) == .readServerName)
        // Another app, or ad hoc code, is not what the rule names.
        #expect(try decide(bare(probe, ["pypi.org"], port: 22), .blockAll) == .drop(reason: "no_rule"))
        #expect(try decide(bare(adHoc, ["pypi.org"], port: 22), .blockAll) == .drop(reason: "adhoc_code"))
    }

    @Test func blockAllWithNothingCoveringTheNameFallsBackToTheServerName() throws {
        // The app may name a covered server the resolver answered from its cache, unseen.
        #expect(try decide(bare(curl, ["evil.example.net"]), .blockAll) == .readServerName)
        #expect(try decide(bare(curl, ["evil.example.net"], port: 22), .blockAll) == .drop(reason: "no_host"))
        #expect(try decide(bare(probe, ["evil.example.net"]), .blockAll) == .drop(reason: "no_rule"))
    }

    @Test func anApprovalCoversTheDNSName() throws {
        let approved = context(approved: [key(agent, "other.example.com"), key(adHoc, "example.org")])
        #expect(try decide(bare(agent, ["other.example.com"], port: 22), .ask, approved) == .allow(reason: "approval;dns_name"))
        #expect(try decide(bare(adHoc, ["example.org"], port: 22), .ask, approved) == .allow(reason: "approval;dns_name"))
        #expect(try decide(bare(agent, ["other.example.com"]), .ask, approved) == .readServerName)
        // Approvals count only in ask mode, and only for the app they name.
        #expect(try decide(bare(agent, ["other.example.com"], port: 22), .blockAll, approved) == .drop(reason: "no_host"))
        #expect(try decide(bare(probe, ["other.example.com"], port: 22), .ask, approved)
            == .ask(reason: "no_rule", addressMatches: true))
    }

    @Test func askModeAsksAboutTheDNSNameBeforeTheAppSendsAnything() throws {
        let expected = FlowVerdict.ask(reason: "no_rule", addressMatches: true)
        #expect(try decide(bare(probe, ["example.org"]), .ask) == expected)
        #expect(try decide(bare(adHoc, ["example.org"]), .ask) == expected)
        // Ports without a TLS server name had no host to ask about before.
        #expect(try decide(bare(probe, ["example.org"], port: 22), .ask) == expected)
        #expect(try decide(bare(probe, ["example.org"], port: 443, tcp: false), .ask) == expected)
        // The event names the DNS name.
        let line = try #require(JSONSerialization.jsonObject(with: Data(FlowLogLine(
            flow: bare(probe, ["example.org"]), verdict: expected, snapshot: try policySnapshot(.ask)).json().utf8)) as? [String: Any])
        #expect(line["host"] as? String == "example.org" && line["verdict"] as? String == "ask")
    }

    @Test func severalNamesOrNoneKeepTheServerNamePath() throws {
        let shared: Set<String> = ["a.example.com", "b.example.com"]
        #expect(try decide(bare(probe, shared), .ask) == .readServerName)
        #expect(try decide(bare(probe, shared, port: 22), .ask) == .drop(reason: "no_host"))
        #expect(try decide(bare(curl, ["pypi.org", "files.example.com"], port: 22), .blockAll) == .drop(reason: "no_host"))
        #expect(try decide(bare(probe, []), .ask) == .readServerName)
        // A name without the address it came with names nothing.
        #expect(try decide(bare(curl, ["pypi.org"], port: 22, address: nil), .blockAll) == .drop(reason: "no_host"))
    }

    @Test func aServerNameOtherThanTheDNSNameIsDroppedUnlessCovered() throws {
        // block-all, a rule for the DNS name: the hello must name it, or a covered host.
        let pypi = bare(curl, ["pypi.org"])
        #expect(try decide(pypi, serverName: "pypi.org", .blockAll) == .allow(reason: "rule_line_8;server_name"))
        #expect(try decide(pypi, serverName: "PyPI.org", .blockAll) == .allow(reason: "rule_line_8;server_name"))
        #expect(try decide(pypi, serverName: "evil.example.net", .blockAll) == .drop(reason: "server_name_mismatch"))

        // A covered server name is still checked against the address, by lookup.
        let other = bare(agent, ["other.example.com"])
        #expect(try decide(other, serverName: "api.example.com", .blockAll) == .resolveHost("api.example.com"))
        #expect(try decide(other, serverName: "api.example.com", .blockAll, context(answers: ["api.example.com": [here]]))
            == .allow(reason: "rule_line_3;server_name"))
        #expect(try decide(other, serverName: "api.example.com", .blockAll, context(answers: ["api.example.com": ["198.51.100.9"]]))
            == .drop(reason: "server_name_mismatch"))

        // ask, after an approval of the DNS name: never a second question about another name.
        let approved = context(approved: [key(probe, "example.org")])
        let flow = bare(probe, ["example.org"])
        #expect(try decide(flow, serverName: "example.org", .ask, approved) == .allow(reason: "approval;server_name"))
        #expect(try decide(flow, serverName: "evil.example.net", .ask, approved) == .drop(reason: "server_name_mismatch"))
        let both = context(approved: [key(probe, "example.org"), key(probe, "evil.example.net")],
                           answers: ["evil.example.net": [here]])
        #expect(try decide(flow, serverName: "evil.example.net", .ask, both) == .allow(reason: "approval;server_name"))
        // An unreadable hello still fails closed.
        #expect(FilterPolicy.decide(flow, serverName: .deny("tls_unparsed"), snapshot: try policySnapshot(.ask), context: approved)
            == .drop(reason: "tls_unparsed"))
        #expect(FilterPolicy.decide(flow, serverName: .deny("sni_missing"), snapshot: try policySnapshot(.ask), context: approved)
            == .drop(reason: "sni_missing"))
    }

    @Test func dnsNamesPassTheAddressCheck() throws {
        // Several names: the server name path asks about the hello's name with no lookup when
        // the resolver gave the address for it, and looks other names up as before.
        let shared = bare(probe, ["a.example.com", "b.example.com"])
        #expect(try decide(shared, serverName: "b.example.com", .ask) == .ask(reason: "no_rule", addressMatches: true))
        #expect(try decide(shared, serverName: "c.example.com", .ask) == .resolveHost("c.example.com"))
        // A host name from the system counts the same way, even when blackice's own lookup got
        // other answers (round robin).
        let named = bare(agent, ["api.example.com"], host: "api.example.com")
        #expect(try decide(named, .blockAll) == .allow(reason: "rule_line_3"))
        #expect(try decide(named, .blockAll, context(answers: ["api.example.com": ["198.51.100.9"]])) == .allow(reason: "rule_line_3"))
        // A host name from the system wins over a DNS name.
        #expect(try decide(bare(agent, ["api.example.com"], host: "other.example.com"), .blockAll) == .drop(reason: "no_rule"))
    }

    @Test func acceptAllIsUntouched() throws {
        #expect(try decide(bare(probe, ["example.org"]), .acceptAll) == .allow(reason: "accept_all"))
        #expect(try decide(bare(probe, ["example.org"], port: 22), .acceptAll) == .allow(reason: "accept_all"))
        #expect(try decide(bare(probe, ["example.org"]), serverName: "evil.example.net", .acceptAll) == .allow(reason: "accept_all"))
    }

    @Test func holdLimits() {
        let limit = FilterPolicy.connectedHoldSeconds
        #expect(limit == 8)
        // BSD sockets on 443: the server already has the TCP connection and waits for a hello.
        #expect(FilterPolicy.holdLimit(bare(probe, ["example.org"]), afterServerName: false) == limit)
        #expect(FilterPolicy.holdLimit(bare(probe, []), afterServerName: true) == limit)
        // Paused after the hello was read.
        #expect(FilterPolicy.holdLimit(bare(probe, [], host: "example.org"), afterServerName: true) == limit)
        // UDP: macOS drops a paused UDP flow after 10 s.
        #expect(FilterPolicy.holdLimit(bare(probe, [], tcp: false, host: "example.org"), afterServerName: false) == limit)
        // A host name from the system (URLSession, Network.framework) waits for the whole timeout,
        // and so does another port, where the server may speak first.
        #expect(FilterPolicy.holdLimit(bare(probe, [], host: "example.org"), afterServerName: false) == nil)
        #expect(FilterPolicy.holdLimit(bare(probe, ["example.org"], port: 22), afterServerName: false) == nil)

        #expect(FilterPolicy.needsServerName(bare(probe, ["example.org"])))
        #expect(!FilterPolicy.needsServerName(bare(probe, ["example.org"], port: 22)))
        #expect(!FilterPolicy.needsServerName(bare(probe, [], host: "example.org")))
        #expect(!FilterPolicy.needsServerName(bare(probe, [], tcp: false)))
    }

    @Test func logLines() throws {
        let snapshot = try policySnapshot(.blockAll)
        let dns = FlowLogLine(flow: bare(signed("com.apple.mDNSResponder", nil), [], port: 53, tcp: false),
                              verdict: .learnNames, snapshot: snapshot)
        let read = try #require(JSONSerialization.jsonObject(with: Data(dns.json().utf8)) as? [String: Any])
        #expect(read["verdict"] as? String == "allow" && read["reason"] as? String == "system_resolver")
        let allowed = FlowLogLine(flow: bare(curl, ["pypi.org"], port: 22), verdict: .allow(reason: "rule_line_8;dns_name"),
                                  snapshot: snapshot)
        #expect(allowed.json().contains(#""host":"pypi.org""#))
        // Several names: no host in the line.
        let shared = FlowLogLine(flow: bare(curl, ["a.example.com", "b.example.com"], port: 22),
                                 verdict: .drop(reason: "no_host"), snapshot: snapshot)
        #expect(!shared.json().contains(#""host":"#))
    }
}
