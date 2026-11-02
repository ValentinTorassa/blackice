import Foundation
import Testing
@testable import NetshieldCore

// The extension's decisions, with fake flows and identities. Rule lines: 3 for the agent,
// 8 for the system curl.
let policyRules = """
mode = "block-all"

[[allow]]
app = "com.example.agent"
team = "ABCDE12345"
hosts = ["api.example.com"]

[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

"""

func policySnapshot(_ mode: Mode, generation: UInt64 = 7) throws -> ProviderConfiguration {
    try ProviderConfiguration(generation: generation, mode: mode, configText: policyRules)
}

private func signed(_ id: String, _ team: String?) -> IdentityResolution {
    .verified(SigningIdentity(signingID: id, teamID: team))
}

private let agent = signed("com.example.agent", "ABCDE12345")
private let curl = signed("com.apple.curl", nil)
private let probe = signed("com.valentorassa.netshield.probe", "ABCDE12345")
private let resolver = IdentityResolution.verified(FilterPolicy.systemResolver)

private func flow(_ identity: IdentityResolution, _ host: String?, port: UInt16? = 443, tcp: Bool = true,
                  direction: FlowDirection = .outbound, internet: Bool = true) -> FlowFacts {
    FlowFacts(direction: direction, identity: identity, internetSocket: internet, tcp: tcp, hostname: host, port: port)
}

/// Flows whose block-all verdicts the tests pin down, used again to compare ask with block-all.
private let blockAllCases: [(FlowFacts, FlowVerdict)] = [
    (flow(agent, "api.example.com"), .allow(reason: "rule_line_3")),
    (flow(agent, "API.Example.COM."), .allow(reason: "rule_line_3")),
    (flow(agent, "api.example.com", port: 8443), .allow(reason: "rule_line_3")),
    (flow(agent, "other.example.com"), .drop(reason: "no_rule")),
    (flow(curl, "pypi.org"), .allow(reason: "rule_line_8")),
    (flow(probe, "pypi.org"), .drop(reason: "no_rule")),
    // Same signing identifier, another team or none: not the app the rule names.
    (flow(signed("com.example.agent", "ZZZZZ99999"), "api.example.com"), .drop(reason: "no_rule")),
    (flow(signed("com.example.agent", nil), "api.example.com"), .drop(reason: "no_rule")),
    (flow(.adHoc, "api.example.com"), .drop(reason: "adhoc_code")),
    (flow(.unresolved, "api.example.com"), .drop(reason: "unknown_identity")),
    (flow(.invalidSignature, "api.example.com"), .drop(reason: "invalid_signature")),
    (flow(agent, "api.example.com", internet: false), .drop(reason: "unsupported_socket")),
    (flow(agent, "bad host"), .drop(reason: "hostname_invalid")),
    (flow(agent, "api.example.com\u{0}.evil.net"), .drop(reason: "hostname_invalid")),
    // No host name from the system: read the TLS server name only for an app with a rule.
    (flow(agent, nil), .readServerName),
    (flow(curl, nil), .readServerName),
    (flow(agent, nil, tcp: false), .drop(reason: "no_host")),
    (flow(agent, nil, port: 80), .drop(reason: "no_host")),
    (flow(agent, nil, port: nil), .drop(reason: "no_host")),
    (flow(probe, nil), .drop(reason: "no_rule")),
    // The resolver may reach DNS, nothing else.
    (flow(resolver, nil, port: 53, tcp: false), .allow(reason: "system_resolver")),
    (flow(resolver, nil, port: 443), .drop(reason: "no_rule")),
    (flow(signed("com.apple.mDNSResponder", "ABCDE12345"), nil, port: 53, tcp: false), .drop(reason: "no_rule")),
    (flow(probe, nil, port: 53, tcp: false), .drop(reason: "no_rule")),
]

struct FilterPolicyTests {
    @Test func blockAllAllowsOnlyWhatARuleNames() throws {
        let snapshot = try policySnapshot(.blockAll)
        for (facts, expected) in blockAllCases {
            #expect(FilterPolicy.decide(facts, snapshot: snapshot) == expected, "\(facts)")
        }
    }

    @Test func askDecidesLikeBlockAllAndSaysAskIsPhaseTwo() throws {
        let snapshot = try policySnapshot(.ask)
        for (facts, blockAll) in blockAllCases {
            let expected: FlowVerdict
            if case .drop(let reason) = blockAll { expected = .drop(reason: reason + ";ask_is_phase_2") } else { expected = blockAll }
            #expect(FilterPolicy.decide(facts, snapshot: snapshot) == expected, "\(facts)")
        }
    }

    @Test func acceptAllAllowsEveryOutboundFlow() throws {
        let snapshot = try policySnapshot(.acceptAll)
        for (facts, _) in blockAllCases where facts.identity != resolver {
            #expect(FilterPolicy.decide(facts, snapshot: snapshot) == .allow(reason: "accept_all"), "\(facts)")
        }
    }

    @Test func inboundAndResolverPassInEveryMode() throws {
        for mode in Mode.allCases {
            let snapshot = try policySnapshot(mode)
            let inbound = flow(.adHoc, nil, port: 22, direction: .inbound)
            #expect(FilterPolicy.decide(inbound, snapshot: snapshot) == .allow(reason: "inbound_not_filtered"))
            let dns = flow(resolver, nil, port: 53, tcp: false)
            #expect(FilterPolicy.decide(dns, snapshot: snapshot) == .allow(reason: "system_resolver"))
        }
        // A direction NetworkExtension did not report is treated as outbound.
        let unknown = flow(probe, "pypi.org", direction: .unknown)
        #expect(FilterPolicy.decide(unknown, snapshot: try policySnapshot(.blockAll)) == .drop(reason: "no_rule"))
    }

    @Test func nothingPassesWithoutAConfiguration() {
        for facts in [flow(curl, "pypi.org"), flow(resolver, nil, port: 53, tcp: false),
                      flow(agent, nil, direction: .inbound)] {
            #expect(FilterPolicy.decide(facts, snapshot: nil) == .drop(reason: "configuration_unavailable"))
        }
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: .serverName("pypi.org"), snapshot: nil)
            == .drop(reason: "configuration_unavailable"))
    }

    @Test func decisionOnTheServerName() throws {
        let blockAll = try policySnapshot(.blockAll)
        let held = flow(agent, nil)
        #expect(FilterPolicy.decide(held, serverName: .serverName("api.example.com"), snapshot: blockAll)
            == .allow(reason: "rule_line_3;server_name"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("API.EXAMPLE.COM"), snapshot: blockAll)
            == .allow(reason: "rule_line_3;server_name"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("evil.example.net"), snapshot: blockAll)
            == .drop(reason: "no_rule"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("pypi.org"), snapshot: blockAll)
            == .drop(reason: "no_rule"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("bad name"), snapshot: blockAll)
            == .drop(reason: "server_name_invalid"))
        #expect(FilterPolicy.decide(held, serverName: .deny("tls_unparsed"), snapshot: blockAll)
            == .drop(reason: "tls_unparsed"))
        #expect(FilterPolicy.decide(held, serverName: .needMore(300), snapshot: blockAll) == .readServerName)
        #expect(FilterPolicy.decide(flow(.adHoc, nil), serverName: .serverName("api.example.com"), snapshot: blockAll)
            == .drop(reason: "adhoc_code"))

        let ask = try policySnapshot(.ask)
        #expect(FilterPolicy.decide(held, serverName: .serverName("api.example.com"), snapshot: ask)
            == .allow(reason: "rule_line_3;server_name"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("evil.example.net"), snapshot: ask)
            == .drop(reason: "no_rule;ask_is_phase_2"))
        #expect(FilterPolicy.decide(held, serverName: .deny("server_name_timeout"), snapshot: ask)
            == .drop(reason: "server_name_timeout;ask_is_phase_2"))

        // The mode can change to accept-all while a flow is held.
        #expect(FilterPolicy.decide(held, serverName: .serverName("evil.example.net"), snapshot: try policySnapshot(.acceptAll))
            == .allow(reason: "accept_all"))
    }

    @Test func serverNameReaderFeedsThePolicy() throws {
        let hello = clientHello("pypi.org")
        var reader = TLSServerNameReader()
        // The extension peeks the 5-byte record header first, then the whole record.
        let first = reader.receive(hello.prefix(5), offset: 0)
        #expect(first == .needMore(hello.count))
        let second = reader.receive(hello, offset: 0)
        #expect(second == .serverName("pypi.org"))
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: second, snapshot: try policySnapshot(.blockAll))
            == .allow(reason: "rule_line_8;server_name"))

        // Bytes after the ones already seen, and a repeated prefix, are both accepted.
        var pieces = TLSServerNameReader()
        _ = pieces.receive(hello.prefix(5), offset: 0)
        #expect(pieces.receive(hello.dropFirst(5), offset: 5) == .serverName("pypi.org"))
    }

    @Test func serverNameReaderFailsClosed() {
        let hello = clientHello("pypi.org")
        var gap = TLSServerNameReader()
        #expect(gap.receive(hello.dropFirst(5), offset: 5) == .deny("tls_unparsed"))
        var negative = TLSServerNameReader()
        #expect(negative.receive(hello, offset: -1) == .deny("tls_unparsed"))
        var changed = TLSServerNameReader()
        _ = changed.receive(hello.prefix(5), offset: 0)
        var tampered = hello
        tampered[1] = 0x02
        #expect(changed.receive(tampered, offset: 0) == .deny("tls_unparsed"))
        var huge = TLSServerNameReader()
        #expect(huge.receive(Data(count: TLSClientHello.maximumBytes + 1), offset: 0) == .deny("tls_unparsed"))
        var plaintext = TLSServerNameReader()
        #expect(plaintext.receive(Data("GET / HTTP/1.1\r\n".utf8), offset: 0) == .deny("not_tls"))
        var noName = TLSServerNameReader()
        #expect(noName.receive(clientHello(nil), offset: 0) == .deny("sni_missing"))
    }
}

struct FlowLogLineTests {
    private func object(_ line: FlowLogLine) throws -> [String: Any] {
        let json = line.json()
        #expect(!json.contains("\n"))
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func fieldsAndOrder() throws {
        let snapshot = try policySnapshot(.blockAll, generation: 12)
        let line = FlowLogLine(flow: flow(agent, "api.example.com"), verdict: .allow(reason: "rule_line_3"), snapshot: snapshot)
        #expect(line.json() == #"{"app":"ABCDE12345/com.example.agent","event":"flow","generation":12,"#
            + #""host":"api.example.com","mode":"block-all","port":443,"reason":"rule_line_3","verdict":"allow"}"#)
    }

    @Test func serverNameHoldAndNoConfiguration() throws {
        let read = try object(FlowLogLine(flow: flow(curl, nil), verdict: .allow(reason: "rule_line_8;server_name"),
                                          snapshot: try policySnapshot(.blockAll), serverName: "pypi.org"))
        #expect(read["host"] as? String == "pypi.org" && read["app"] as? String == "apple/com.apple.curl")
        let hold = try object(FlowLogLine(flow: flow(agent, nil, port: nil), verdict: .readServerName, snapshot: nil))
        #expect(hold["verdict"] as? String == "hold" && hold["reason"] as? String == "reading_server_name")
        #expect(hold["mode"] as? String == "none" && hold["generation"] as? Int == 0)
        #expect(hold["host"] == nil && hold["port"] == nil)
        let adHoc = try object(FlowLogLine(flow: flow(.adHoc, nil), verdict: .drop(reason: "adhoc_code"), snapshot: nil))
        #expect(adHoc["app"] as? String == "adhoc" && adHoc["verdict"] as? String == "drop")
    }

    @Test func hostileHostStaysOneEncodedField() throws {
        let hostile = "evil\"}\n{\"verdict\":\"allow\u{1b}[2J" + String(repeating: "a", count: 400)
        let line = FlowLogLine(flow: flow(probe, hostile), verdict: .drop(reason: "hostname_invalid"),
                               snapshot: try policySnapshot(.blockAll))
        let decoded = try object(line)
        #expect(decoded["verdict"] as? String == "drop")
        #expect(decoded["host"] as? String == String(hostile.prefix(253)))
        #expect(!line.json().unicodeScalars.contains { $0.value < 0x20 })
    }
}
