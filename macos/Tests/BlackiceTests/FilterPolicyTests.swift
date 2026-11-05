import Foundation
import Testing
@testable import BlackiceCore

// The extension's decisions, with fake flows, identities, approvals and resolver answers.
// Rule lines: 3 for the agent, 8 for the system curl.
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
private let probe = signed("com.valentorassa.blackice.probe", "ABCDE12345")
private let resolver = IdentityResolution.verified(FilterPolicy.systemResolver)
let testCDHash = "3f1c6a0b9e2d4c5a7b8f9e0d1c2b3a4f5e6d7c8b"
private let adHoc = IdentityResolution.adHoc(cdhash: testCDHash)
private let flowAddress = "203.0.113.7"

private func flow(_ identity: IdentityResolution, _ host: String?, port: UInt16? = 443, tcp: Bool = true,
                  direction: FlowDirection = .outbound, internet: Bool = true,
                  address: String? = flowAddress, process: IdentityResolution? = nil,
                  dnsNames: Set<String> = []) -> FlowFacts {
    FlowFacts(direction: direction, identity: identity, internetSocket: internet, tcp: tcp, hostname: host, port: port,
              remoteAddress: address.flatMap(IPAddress.init), process: process, dnsNames: dnsNames)
}

/// Every host resolves to the flow's address, and nothing is approved.
private var matching: PolicyContext { PolicyContext(approved: { _, _ in false }, address: { _, _ in .match }) }

/// Approvals and resolver answers by host; a host without answers is not looked up yet.
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

/// Flows whose block-all verdicts the tests pin down, with every host resolving to the flow's address.
private let blockAllCases: [(FlowFacts, FlowVerdict)] = [
    // TCP on the TLS port: the rule matches, and the server name is read before the flow passes.
    (flow(agent, "api.example.com"), .readServerName),
    (flow(agent, "API.Example.COM."), .readServerName),
    (flow(agent, "api.example.com", port: 8443), .allow(reason: "rule_line_3")),
    (flow(agent, "api.example.com", tcp: false), .allow(reason: "rule_line_3")),
    (flow(agent, "other.example.com"), .drop(reason: "no_rule")),
    (flow(curl, "pypi.org"), .readServerName),
    (flow(curl, "pypi.org", port: 80), .allow(reason: "rule_line_8")),
    (flow(probe, "pypi.org"), .drop(reason: "no_rule")),
    // Same signing identifier, another team or none: not the app the rule names.
    (flow(signed("com.example.agent", "ZZZZZ99999"), "api.example.com"), .drop(reason: "no_rule")),
    (flow(signed("com.example.agent", nil), "api.example.com"), .drop(reason: "no_rule")),
    (flow(adHoc, "api.example.com"), .drop(reason: "adhoc_code")),
    (flow(.unresolved, "api.example.com"), .drop(reason: "unknown_identity")),
    (flow(.invalidSignature, "api.example.com"), .drop(reason: "invalid_signature")),
    (flow(agent, "api.example.com", internet: false), .drop(reason: "unsupported_socket")),
    (flow(agent, "bad host"), .drop(reason: "hostname_invalid")),
    (flow(agent, "api.example.com\u{0}.evil.net"), .drop(reason: "hostname_invalid")),
    (flow(agent, "api.example.com", address: nil), .drop(reason: "no_address")),
    // No host name from the system: read the TLS server name only for an app with a rule.
    (flow(agent, nil), .readServerName),
    (flow(curl, nil), .readServerName),
    (flow(agent, nil, tcp: false), .drop(reason: "no_host")),
    (flow(agent, nil, port: 80), .drop(reason: "no_host")),
    (flow(agent, nil, port: nil), .drop(reason: "no_host")),
    (flow(probe, nil), .drop(reason: "no_rule")),
    // The resolver may reach DNS, nothing else; its answers are read to learn names.
    (flow(resolver, nil, port: 53, tcp: false), .learnNames),
    (flow(resolver, nil, port: 53), .learnNames),
    (flow(resolver, nil, port: 443), .drop(reason: "no_rule")),
    (flow(signed("com.apple.mDNSResponder", "ABCDE12345"), nil, port: 53, tcp: false), .drop(reason: "no_rule")),
    (flow(probe, nil, port: 53, tcp: false), .drop(reason: "no_rule")),
    // A lookup mDNSResponder makes for an app is reported under the app; it is the resolver's.
    (flow(curl, "example.com", port: 53, tcp: false, process: resolver), .learnNames),
    (flow(probe, "example.com", port: 443, process: resolver), .drop(reason: "no_rule")),
    (flow(probe, "example.com", port: 53, tcp: false, process: probe), .drop(reason: "no_rule")),
]

struct FilterPolicyTests {
    @Test func blockAllAllowsOnlyWhatARuleNames() throws {
        let snapshot = try policySnapshot(.blockAll)
        for (facts, expected) in blockAllCases {
            #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: matching) == expected, "\(facts)")
        }
    }

    @Test func blockAllChecksTheAddressAgainstTheRuleHost() throws {
        let snapshot = try policySnapshot(.blockAll)
        let facts = flow(agent, "api.example.com")
        // Not looked up yet: look it up, then decide again.
        #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: context()) == .resolveHost("api.example.com"))
        // CDN-style answers: the flow's address is one of several, of both families.
        let cdn = context(answers: ["api.example.com": ["198.51.100.1", flowAddress, "2001:db8::1"]])
        #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: cdn) == .readServerName)
        #expect(FilterPolicy.decide(flow(agent, "api.example.com", port: 8443), snapshot: snapshot, context: cdn)
            == .allow(reason: "rule_line_3"))
        // The app named the rule's host but connects somewhere else.
        let elsewhere = context(answers: ["api.example.com": ["198.51.100.1", "198.51.100.2"]])
        #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: elsewhere) == .drop(reason: "address_mismatch"))
        // A failed lookup leaves no answers, which nothing matches.
        let failed = context(answers: ["api.example.com": []])
        #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: failed) == .drop(reason: "address_mismatch"))
        // A link-local answer counts only on its own interface.
        let link = context(answers: ["api.example.com": ["fe80::7%1"]])
        let linkFlow = { (address: String) in flow(agent, "api.example.com", port: 8443, address: address) }
        #expect(FilterPolicy.decide(linkFlow("fe80::7%1"), snapshot: snapshot, context: link) == .allow(reason: "rule_line_3"))
        #expect(FilterPolicy.decide(linkFlow("fe80::7%2"), snapshot: snapshot, context: link) == .drop(reason: "address_mismatch"))
        #expect(FilterPolicy.decide(linkFlow("fe80::7"), snapshot: snapshot, context: link) == .drop(reason: "address_mismatch"))
        // No rule by name: dropped without a lookup.
        #expect(FilterPolicy.decide(flow(agent, "other.example.com"), snapshot: snapshot, context: context())
            == .drop(reason: "no_rule"))
        // Approvals count only in ask mode.
        let approved = context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": [flowAddress]])
        #expect(FilterPolicy.decide(flow(agent, "other.example.com"), snapshot: snapshot, context: approved)
            == .drop(reason: "no_rule"))
    }

    @Test func askAllowsRulesAndApprovalsAndAsksAboutTheRest() throws {
        let snapshot = try policySnapshot(.ask)
        let here = [flowAddress]
        let cases: [(FlowFacts, PolicyContext, FlowVerdict)] = [
            (flow(agent, "api.example.com"), context(answers: ["api.example.com": here]), .readServerName),
            (flow(agent, "api.example.com", port: 8443), context(answers: ["api.example.com": here]),
             .allow(reason: "rule_line_3")),
            // Looked up even without a rule, so the paused flow knows whether an approval may release it.
            (flow(agent, "other.example.com"), context(), .resolveHost("other.example.com")),
            (flow(agent, "other.example.com"), context(answers: ["other.example.com": here]),
             .ask(reason: "no_rule", addressMatches: true)),
            (flow(agent, "other.example.com"), context(answers: ["other.example.com": ["198.51.100.9"]]),
             .ask(reason: "no_rule", addressMatches: false)),
            // An approval counts once the address checks out (on the TLS port, the server name is
            // read next); a mismatch asks again.
            (flow(agent, "other.example.com"),
             context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": here]),
             .readServerName),
            (flow(agent, "other.example.com"),
             context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": ["198.51.100.9"]]),
             .ask(reason: "address_mismatch", addressMatches: false)),
            (flow(agent, "api.example.com"), context(answers: ["api.example.com": ["198.51.100.9"]]),
             .ask(reason: "address_mismatch", addressMatches: false)),
            // An approval names the app and the host, any port.
            (flow(agent, "other.example.com", port: 8443),
             context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": here]),
             .allow(reason: "approval")),
            // Ad hoc code is asked about and approved by its cdhash.
            (flow(adHoc, "example.org"), context(answers: ["example.org": here]), .ask(reason: "no_rule", addressMatches: true)),
            (flow(adHoc, "example.org", port: 22), context(approved: [key(adHoc, "example.org")], answers: ["example.org": here]),
             .allow(reason: "approval")),
            // Another build of it has another cdhash.
            (flow(.adHoc(cdhash: String(repeating: "e", count: 40)), "example.org"),
             context(approved: [key(adHoc, "example.org")], answers: ["example.org": here]),
             .ask(reason: "no_rule", addressMatches: true)),
            // An approval for the signed app does not cover other code.
            (flow(probe, "other.example.com"),
             context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": here]),
             .ask(reason: "no_rule", addressMatches: true)),
            // Code that cannot be named is not asked about.
            (flow(.unresolved, "example.org"), context(answers: ["example.org": here]), .drop(reason: "unknown_identity")),
            (flow(.invalidSignature, "example.org"), context(answers: ["example.org": here]), .drop(reason: "invalid_signature")),
            (flow(agent, "example.org", address: nil), context(), .drop(reason: "no_address")),
            // Without a host: read the TLS server name for any app; otherwise ask about the address.
            // QUIC (UDP on 443) is not asked about: apps retry over TCP, where the name is read.
            (flow(probe, nil), context(), .readServerName),
            (flow(adHoc, nil), context(), .readServerName),
            (flow(probe, nil, tcp: false), context(), .drop(reason: "no_host")),
            (flow(probe, nil, port: 80), context(), .ask(reason: "no_rule;address", addressMatches: true)),
            (flow(probe, nil, port: 80), context(approved: [key(probe, flowAddress)]), .allow(reason: "approval;address")),
            (flow(probe, "bad host"), context(), .drop(reason: "hostname_invalid")),
        ]
        for (facts, context, expected) in cases {
            #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: context) == expected, "\(facts)")
        }
    }

    @Test func acceptAllAllowsEveryOutboundFlow() throws {
        let snapshot = try policySnapshot(.acceptAll)
        for (facts, verdict) in blockAllCases {
            // The resolver's DNS passes before the mode is looked at, in every mode, and accept-all
            // does not read it.
            let expected: FlowVerdict = verdict == .learnNames ? .allow(reason: "system_resolver") : .allow(reason: "accept_all")
            #expect(FilterPolicy.decide(facts, snapshot: snapshot, context: context()) == expected, "\(facts)")
        }
    }

    @Test func inboundAndResolverPassInEveryMode() throws {
        for mode in Mode.allCases {
            let snapshot = try policySnapshot(mode)
            let inbound = flow(adHoc, nil, port: 22, direction: .inbound)
            #expect(FilterPolicy.decide(inbound, snapshot: snapshot, context: context()) == .allow(reason: "inbound_not_filtered"))
            let dns = flow(resolver, nil, port: 53, tcp: false)
            let expected: FlowVerdict = mode == .acceptAll ? .allow(reason: "system_resolver") : .learnNames
            #expect(FilterPolicy.decide(dns, snapshot: snapshot, context: context()) == expected)
            #expect(expected.reason == "system_resolver")
        }
        // A direction NetworkExtension did not report is treated as outbound.
        let unknown = flow(probe, "pypi.org", direction: .unknown)
        #expect(FilterPolicy.decide(unknown, snapshot: try policySnapshot(.blockAll), context: matching) == .drop(reason: "no_rule"))
    }

    @Test func nothingPassesWithoutAConfiguration() {
        for facts in [flow(curl, "pypi.org"), flow(resolver, nil, port: 53, tcp: false),
                      flow(agent, nil, direction: .inbound)] {
            #expect(FilterPolicy.decide(facts, snapshot: nil, context: matching) == .drop(reason: "configuration_unavailable"))
        }
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: .serverName("pypi.org"), snapshot: nil, context: matching)
            == .drop(reason: "configuration_unavailable"))
    }

    @Test func decisionOnTheServerName() throws {
        let blockAll = try policySnapshot(.blockAll)
        let held = flow(agent, nil)
        func decide(_ result: TLSHelloResult, _ snapshot: ProviderConfiguration, _ facts: FlowFacts = held,
                    _ context: PolicyContext = matching) -> FlowVerdict {
            FilterPolicy.decide(facts, serverName: result, snapshot: snapshot, context: context)
        }
        #expect(decide(.serverName("api.example.com"), blockAll) == .allow(reason: "rule_line_3;server_name"))
        #expect(decide(.serverName("API.EXAMPLE.COM"), blockAll) == .allow(reason: "rule_line_3;server_name"))
        #expect(decide(.serverName("evil.example.net"), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(.serverName("pypi.org"), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(.serverName("bad name"), blockAll) == .drop(reason: "server_name_invalid"))
        #expect(decide(.deny("tls_unparsed"), blockAll) == .drop(reason: "tls_unparsed"))
        #expect(decide(.needMore(300), blockAll) == .readServerName)
        #expect(decide(.serverName("api.example.com"), blockAll, flow(adHoc, nil)) == .drop(reason: "adhoc_code"))
        // The server name is checked against the address like a host name from the system.
        #expect(decide(.serverName("api.example.com"), blockAll, held, context()) == .resolveHost("api.example.com"))
        #expect(decide(.serverName("api.example.com"), blockAll, held, context(answers: ["api.example.com": ["198.51.100.9"]]))
            == .drop(reason: "address_mismatch"))

        let ask = try policySnapshot(.ask)
        #expect(decide(.serverName("api.example.com"), ask) == .allow(reason: "rule_line_3;server_name"))
        #expect(decide(.serverName("evil.example.net"), ask) == .ask(reason: "no_rule", addressMatches: true))
        #expect(decide(.serverName("evil.example.net"), ask, held,
                       context(approved: [key(agent, "evil.example.net")], answers: ["evil.example.net": [flowAddress]]))
            == .allow(reason: "approval;server_name"))
        #expect(decide(.serverName("example.org"), ask, flow(adHoc, nil)) == .ask(reason: "no_rule", addressMatches: true))
        // An unreadable ClientHello leaves no host to ask about. One with no server name, on a flow
        // with no name, is asked about by its address.
        #expect(decide(.deny("server_name_timeout"), ask) == .drop(reason: "server_name_timeout"))
        #expect(decide(.deny("sni_missing"), ask) == .ask(reason: "no_rule;address;sni_missing", addressMatches: true))
        #expect(decide(.deny("sni_missing"), blockAll) == .drop(reason: "sni_missing"))

        // The mode can change to accept-all while a flow is held.
        #expect(decide(.serverName("evil.example.net"), try policySnapshot(.acceptAll)) == .allow(reason: "accept_all"))
    }

    @Test func aHostNameFromTheSystemIsHeldToItsServerName() throws {
        // URLSession and Network.framework flows carry a host name the app chose. A rule for that
        // host must not let the app reach another site on the same address by naming it in its hello.
        let blockAll = try policySnapshot(.blockAll)
        let named = flow(agent, "api.example.com")
        let here = context(answers: ["api.example.com": [flowAddress]])
        func hello(_ name: String, _ snapshot: ProviderConfiguration, _ facts: FlowFacts,
                   _ context: PolicyContext) -> FlowVerdict {
            FilterPolicy.decide(facts, serverName: .serverName(name), snapshot: snapshot, context: context)
        }
        #expect(FilterPolicy.decide(named, snapshot: blockAll, context: here) == .readServerName)
        #expect(hello("api.example.com", blockAll, named, here) == .allow(reason: "rule_line_3;server_name"))
        #expect(hello("API.Example.com.", blockAll, named, here) == .allow(reason: "rule_line_3;server_name"))
        // Another site behind the same address, or a host another app's rule names: dropped.
        #expect(hello("evil.example.net", blockAll, named, matching) == .drop(reason: "server_name_mismatch"))
        #expect(hello("pypi.org", blockAll, named, matching) == .drop(reason: "server_name_mismatch"))
        // A server name the app's own rule also covers goes on to its own address check.
        let twoHosts = try ProviderConfiguration(generation: 7, mode: .blockAll, configText: """
            mode = "block-all"

            [[allow]]
            app = "com.example.agent"
            team = "ABCDE12345"
            hosts = ["api.example.com", "cdn.example.com"]

            """)
        #expect(hello("cdn.example.com", twoHosts, named, here) == .resolveHost("cdn.example.com"))
        #expect(hello("cdn.example.com", twoHosts, named, context(answers: ["cdn.example.com": [flowAddress]]))
            == .allow(reason: "rule_line_3;server_name"))
        #expect(hello("cdn.example.com", twoHosts, named, context(answers: ["cdn.example.com": ["198.51.100.9"]]))
            == .drop(reason: "server_name_mismatch"))

        // Ask mode, after an approval of the host name: the hello must name it, never a second question.
        let ask = try policySnapshot(.ask)
        let other = flow(agent, "other.example.com")
        let approved = context(approved: [key(agent, "other.example.com")], answers: ["other.example.com": [flowAddress]])
        #expect(FilterPolicy.decide(other, snapshot: ask, context: approved) == .readServerName)
        #expect(hello("other.example.com", ask, other, approved) == .allow(reason: "approval;server_name"))
        #expect(hello("evil.example.net", ask, other, approved) == .drop(reason: "server_name_mismatch"))
        // Not approved yet: asked about by its host name before it connects, with the whole timeout
        // to wait; an approval then resumes it into the hold.
        #expect(FilterPolicy.decide(other, snapshot: ask, context: context(answers: ["other.example.com": [flowAddress]]))
            == .ask(reason: "no_rule", addressMatches: true))
        #expect(FilterPolicy.holdLimit(other, afterServerName: false) == nil)
        #expect(FilterPolicy.needsServerName(other))

        // Off the TLS port, or over UDP, the host name decides as before; so does a host name that
        // no rule covers, or that fails its address check.
        #expect(FilterPolicy.decide(flow(agent, "api.example.com", port: 8443), snapshot: blockAll, context: here)
            == .allow(reason: "rule_line_3"))
        #expect(FilterPolicy.decide(flow(agent, "api.example.com", tcp: false), snapshot: blockAll, context: here)
            == .allow(reason: "rule_line_3"))
        #expect(FilterPolicy.decide(flow(agent, "evil.example.net"), snapshot: blockAll, context: matching)
            == .drop(reason: "no_rule"))
        #expect(FilterPolicy.decide(named, snapshot: blockAll, context: context(answers: ["api.example.com": ["198.51.100.9"]]))
            == .drop(reason: "address_mismatch"))
    }

    @Test func anEncryptedClientHelloIsJudgedOnItsOuterName() throws {
        var reader = TLSServerNameReader()
        let ech = reader.receive(clientHello("pypi.org", extra: [0xfe, 0x0d, 0, 4, 0x42, 0x87, 0x19, 0xff]), offset: 0)
        #expect(ech == .serverName("pypi.org", echPresent: true))
        let blockAll = try policySnapshot(.blockAll)
        let ask = try policySnapshot(.ask)
        let approved = context(approved: [key(agent, "api.example.com"), key(probe, "example.org")],
                               answers: ["api.example.com": [flowAddress], "example.org": [flowAddress]])
        let frontEnd = "cloudflare-ech.com"
        let cases: [(FlowFacts, String, ProviderConfiguration, PolicyContext, FlowVerdict)] = [
            // A decoy extension (GREASE) leaves the real host in the clear: it passes as without ECH.
            (flow(curl, nil), "pypi.org", blockAll, matching, .allow(reason: "rule_line_8;server_name;ech")),
            (flow(curl, nil, dnsNames: ["pypi.org"]), "pypi.org", blockAll, matching,
             .allow(reason: "rule_line_8;server_name;ech")),
            (flow(agent, "api.example.com"), "api.example.com", blockAll, matching,
             .allow(reason: "rule_line_3;server_name;ech")),
            (flow(probe, "example.org"), "example.org", ask, approved, .allow(reason: "approval;server_name;ech")),
            (flow(signed("com.apple.apsd", nil), nil), "1-courier.push.apple.com", blockAll, matching,
             .allow(reason: "apple_service;server_name;ech")),
            // Real ECH puts the provider's front end in the clear: not the flow's host, so dropped.
            (flow(agent, "api.example.com"), frontEnd, blockAll, matching, .drop(reason: "server_name_mismatch;ech")),
            (flow(curl, nil, dnsNames: ["pypi.org"]), frontEnd, blockAll, matching, .drop(reason: "server_name_mismatch;ech")),
            (flow(probe, "example.org"), frontEnd, ask, approved, .drop(reason: "server_name_mismatch;ech")),
            (flow(curl, nil), frontEnd, blockAll, matching, .drop(reason: "no_rule;ech")),
            // With no host before the hello, ask mode asks about the front end.
            (flow(probe, nil), frontEnd, ask, matching, .ask(reason: "no_rule;ech", addressMatches: true)),
            // A lookup still comes first, and its verdict is not marked; the decision after it is.
            (flow(curl, nil), "pypi.org", blockAll, context(), .resolveHost("pypi.org")),
        ]
        for (facts, name, snapshot, context, expected) in cases {
            let verdict = FilterPolicy.decide(facts, serverName: .serverName(name, echPresent: true), snapshot: snapshot,
                                              context: context)
            #expect(verdict == expected, "\(facts) \(name)")
            // ECH changes only the reason.
            #expect(FilterPolicy.decide(facts, serverName: .serverName(name), snapshot: snapshot, context: context)
                .adding(";ech") == expected, "\(facts) \(name)")
        }
        // The limit: a rule or an approval for a front-end name covers every site behind it.
        let fronted = try ProviderConfiguration(generation: 7, mode: .blockAll, configText: """
            mode = "block-all"

            [[allow]]
            app = "com.apple.curl"
            hosts = ["cloudflare-ech.com"]

            """)
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: .serverName(frontEnd, echPresent: true), snapshot: fronted,
                                    context: matching) == .allow(reason: "rule_line_3;server_name;ech"))
        let frontApproved = context(approved: [key(probe, frontEnd)], answers: [frontEnd: [flowAddress]])
        #expect(FilterPolicy.decide(flow(probe, nil), serverName: .serverName(frontEnd, echPresent: true), snapshot: ask,
                                    context: frontApproved) == .allow(reason: "approval;server_name;ech"))
        // A hosts = ["*"] rule and accept-all check nothing, ECH included.
        let star = try ProviderConfiguration(generation: 7, mode: .blockAll, configText: """
            mode = "block-all"

            [[allow]]
            app = "com.apple.curl"
            hosts = ["*"]

            """)
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: ech, snapshot: star, context: matching)
            == .allow(reason: "rule_line_3"))
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: ech, snapshot: try policySnapshot(.acceptAll), context: matching)
            == .allow(reason: "accept_all"))
        // Code that cannot be named keeps its own reason.
        #expect(FilterPolicy.decide(flow(.unresolved, nil), serverName: ech, snapshot: blockAll, context: matching)
            == .drop(reason: "unknown_identity"))
    }

    @Test func serverNameReaderFeedsThePolicy() throws {
        let hello = clientHello("pypi.org")
        var reader = TLSServerNameReader()
        // The extension peeks the 5-byte record header first, then the whole record.
        let first = reader.receive(hello.prefix(5), offset: 0)
        #expect(first == .needMore(hello.count))
        let second = reader.receive(hello, offset: 0)
        #expect(second == .serverName("pypi.org"))
        #expect(FilterPolicy.decide(flow(curl, nil), serverName: second, snapshot: try policySnapshot(.blockAll), context: matching)
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
        let adHocLine = try object(FlowLogLine(flow: flow(adHoc, nil), verdict: .drop(reason: "adhoc_code"), snapshot: nil))
        #expect(adHocLine["app"] as? String == "cdhash/" + testCDHash && adHocLine["verdict"] as? String == "drop")
    }

    @Test func askAndResolveVerdicts() throws {
        let snapshot = try policySnapshot(.ask)
        let asked = try object(FlowLogLine(flow: flow(agent, "other.example.com"),
                                           verdict: .ask(reason: "address_mismatch", addressMatches: false), snapshot: snapshot))
        #expect(asked["verdict"] as? String == "ask" && asked["reason"] as? String == "address_mismatch")
        let resolving = try object(FlowLogLine(flow: flow(agent, "other.example.com"),
                                               verdict: .resolveHost("other.example.com"), snapshot: snapshot))
        #expect(resolving["verdict"] as? String == "resolve" && resolving["reason"] as? String == "resolving_host")
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
