import Darwin
import Foundation
import Testing
@testable import BlackiceCore

// Connections by address: loopback, flows with no name asked about by their address, approvals of
// an address, and address and CIDR entries in rules. Rule lines: 3 for ssh, 7 for the agent.
private let addressRules = """
mode = "block-all"

[[allow]]
app = "com.apple.ssh"
hosts = ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "10.0.0.5", "*.ts.net"]

[[allow]]
app = "com.example.agent"
team = "ABCDE12345"
hosts = ["api.example.com"]

"""

private func snapshot(_ mode: Mode, _ extra: String = "") throws -> ProviderConfiguration {
    try ProviderConfiguration(generation: 7, mode: mode, configText: extra.isEmpty ? addressRules
        : addressRules.replacingOccurrences(of: "mode = \"block-all\"\n", with: "mode = \"block-all\"\n\(extra)\n"))
}

private func signed(_ id: String, _ team: String?) -> IdentityResolution {
    .verified(SigningIdentity(signingID: id, teamID: team))
}

private let ssh = signed("com.apple.ssh", nil)
private let agent = signed("com.example.agent", "ABCDE12345")
private let probe = signed("com.valentorassa.blackice.probe", "ABCDE12345")
private let adHoc = IdentityResolution.adHoc(cdhash: testCDHash)
private let tailnet = "100.66.32.75"

private func flow(_ identity: IdentityResolution, _ host: String? = nil, port: UInt16? = 22, tcp: Bool = true,
                  address: String? = tailnet, dnsNames: Set<String> = []) -> FlowFacts {
    FlowFacts(direction: .outbound, identity: identity, internetSocket: true, tcp: tcp, hostname: host, port: port,
              remoteAddress: address.flatMap(IPAddress.init), dnsNames: dnsNames)
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

private func decide(_ facts: FlowFacts, _ snapshot: ProviderConfiguration,
                    _ context: PolicyContext = context()) -> FlowVerdict {
    FilterPolicy.decide(facts, snapshot: snapshot, context: context)
}

private func hello(_ result: TLSHelloResult, _ facts: FlowFacts, _ snapshot: ProviderConfiguration,
                   _ context: PolicyContext = context()) -> FlowVerdict {
    FilterPolicy.decide(facts, serverName: result, snapshot: snapshot, context: context)
}

private let asked = FlowVerdict.ask(reason: "no_rule;address", addressMatches: true)

struct LoopbackPolicyTests {
    @Test func loopbackPassesInEveryModeBeforeAnything() throws {
        for mode in Mode.allCases {
            let rules = try snapshot(mode)
            for address in ["127.0.0.1", "127.255.0.9", "::1", "::ffff:127.0.0.1"] {
                // The Tailscale CLI talking to its app: any code, with or without a host name.
                for identity in [probe, adHoc, .unresolved, .invalidSignature] {
                    #expect(decide(flow(identity, port: 49160, address: address), rules) == .allow(reason: "loopback"),
                            "\(mode) \(address)")
                }
                #expect(decide(flow(probe, "localhost", port: 8080, address: address), rules) == .allow(reason: "loopback"))
                #expect(decide(flow(probe, port: 53, tcp: false, address: address), rules) == .allow(reason: "loopback"))
            }
            // Next to loopback, but not it.
            for address in ["128.0.0.1", "126.255.255.255", "::2", "0.0.0.0"] {
                #expect(decide(flow(probe, port: 49160, address: address), rules) != .allow(reason: "loopback"), "\(address)")
            }
            // The system resolver's DNS is still read, wherever it goes.
            let resolver = flow(.verified(FilterPolicy.systemResolver), port: 53, tcp: false, address: "127.0.0.1")
            #expect(decide(resolver, rules) == (mode == .acceptAll ? .allow(reason: "system_resolver") : .learnNames))
        }
    }

    @Test func loopbackFalseFiltersItLikeAnyOtherAddress() throws {
        let cli = flow(probe, port: 49160, address: "127.0.0.1")
        #expect(decide(cli, try snapshot(.acceptAll, "loopback = false")) == .allow(reason: "accept_all"))
        #expect(decide(cli, try snapshot(.blockAll, "loopback = false")) == .drop(reason: "no_rule"))
        let ask = try snapshot(.ask, "loopback = false")
        #expect(decide(cli, ask) == asked)
        #expect(FilterPolicy.eventHost(cli, serverName: nil) == "127.0.0.1")
        #expect(decide(flow(probe, port: 49160, address: "::1"), ask) == asked)
        #expect(decide(cli, ask, context(approved: [key(probe, "127.0.0.1")])) == .allow(reason: "approval;address"))
        #expect(decide(flow(probe, port: 5353, tcp: false, address: "127.0.0.1"), ask) == .drop(reason: "no_host"))
        // A host name goes through the host and address check, as for any host.
        #expect(decide(flow(probe, "localhost", port: 8080, address: "127.0.0.1"), ask) == .resolveHost("localhost"))
        // An address rule can name loopback itself.
        let rule = try ProviderConfiguration(generation: 7, mode: .blockAll, configText: """
            mode = "block-all"
            loopback = false

            [[allow]]
            app = "com.valentorassa.blackice.probe"
            team = "ABCDE12345"
            hosts = ["127.0.0.1"]

            """)
        #expect(!rule.config.loopback)
        #expect(decide(cli, rule) == .allow(reason: "rule_line_4;address"))
        #expect(decide(flow(probe, port: 49160, address: "127.0.0.2"), rule) == .drop(reason: "no_host"))
    }
}

struct AddressOnlyPolicyTests {
    @Test func askModeAsksAboutATCPFlowWithNoNameByItsAddress() throws {
        let ask = try snapshot(.ask)
        let cases: [(FlowFacts, FlowVerdict, String?)] = [
            // ssh to a Tailscale address, with no rule for this app.
            (flow(probe), asked, tailnet),
            (flow(adHoc, port: 8080, address: "198.51.100.4"), asked, "198.51.100.4"),
            // Not multicast: just outside 224.0.0.0/4.
            (flow(probe, address: "223.255.255.255"), asked, "223.255.255.255"),
            (flow(probe, address: "240.0.0.1"), asked, "240.0.0.1"),
            (flow(probe, address: "FD7A:115C:A1E0:0:0:0:0:1"), asked, "fd7a:115c:a1e0::1"),
            (flow(probe, address: "::ffff:198.51.100.4"), asked, "198.51.100.4"),
            // A link-local address is asked about with no interface: the flow gives none, and
            // were one given, the event and its approval would still name the address alone.
            (flow(probe, address: "fe80::7"), asked, "fe80::7"),
            (flow(probe, address: "fe80::7%1"), asked, "fe80::7"),
            // Several names for the address name nothing: asked about by the address.
            (flow(probe, dnsNames: ["a.example.com", "b.example.com"]), asked, tailnet),
            // One name: asked about by that name, as before.
            (flow(probe, dnsNames: ["valensrv.example.ts.net"]), .ask(reason: "no_rule", addressMatches: true),
             "valensrv.example.ts.net"),
            // TCP on 443 still reads the server name first.
            (flow(probe, port: 443), .readServerName, tailnet),
            (flow(probe, port: nil), .drop(reason: "no_host"), tailnet),
            (flow(probe, address: nil), .drop(reason: "no_host"), nil),
            (flow(.unresolved), .drop(reason: "unknown_identity"), tailnet),
        ]
        for (facts, expected, host) in cases {
            #expect(decide(facts, ask) == expected, "\(facts)")
            #expect(FilterPolicy.eventHost(facts, serverName: nil) == host, "\(facts)")
        }
        // The whole timeout, off the TLS port.
        #expect(FilterPolicy.holdLimit(flow(probe), afterServerName: false) == nil)
        // An approval of a link-local address names no interface: it covers the address on each.
        let link = context(approved: [key(probe, "fe80::7")])
        #expect(decide(flow(probe, address: "fe80::7"), ask, link) == .allow(reason: "approval;address"))
        #expect(decide(flow(probe, address: "fe80::7%1"), ask, link) == .allow(reason: "approval;address"))
        #expect(decide(flow(probe, address: "fe80::8"), ask, link) == asked)
    }

    @Test func udpAndMulticastWithNoNameRaiseNoEvent() throws {
        // WebRTC, games, discovery and QUIC would flood the hooks with events that get denied anyway.
        let ask = try snapshot(.ask)
        for (port, address) in [(UInt16(41641), tailnet), (443, "198.51.100.4"), (3478, "2001:db8::1"), (53, "100.100.100.100")] {
            #expect(decide(flow(probe, port: port, tcp: false, address: address), ask) == .drop(reason: "no_host"),
                    "\(address):\(port)")
            #expect(decide(flow(adHoc, port: port, tcp: false, address: address), ask) == .drop(reason: "no_host"))
        }
        // Multicast and broadcast never raise one, over TCP or UDP.
        for address in ["224.0.0.251", "239.255.255.250", "255.255.255.255", "ff02::fb", "ff05::c"] {
            for tcp in [true, false] {
                #expect(decide(flow(probe, port: 1900, tcp: tcp, address: address), ask) == .drop(reason: "no_host"),
                        "\(address) tcp \(tcp)")
            }
        }
        // An approval of the address does not reach UDP either.
        let approved = context(approved: [key(probe, tailnet)])
        #expect(decide(flow(probe, port: 41641, tcp: false), ask, approved) == .drop(reason: "no_host"))
        // A UDP flow with a name is asked about by its name, as before.
        #expect(decide(flow(probe, port: 41641, tcp: false, dnsNames: ["valensrv.example.ts.net"]), ask)
                == .ask(reason: "no_rule", addressMatches: true))
        // Address rules, `*` and loopback still allow UDP.
        #expect(decide(flow(ssh, port: 41641, tcp: false), ask) == .allow(reason: "rule_line_3;address"))
        #expect(decide(flow(probe, port: 41641, tcp: false, address: "127.0.0.1"), ask) == .allow(reason: "loopback"))
    }

    @Test func multicastAndBroadcastAddresses() {
        for text in ["224.0.0.0", "224.0.0.251", "239.255.255.255", "255.255.255.255", "ff00::", "ff02::fb",
                     "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "::ffff:239.255.255.250"] {
            #expect(IPAddress(text)?.isMulticastOrBroadcast == true, "\(text)")
        }
        for text in ["223.255.255.255", "240.0.0.0", "255.255.255.254", "10.0.0.255", "fe80::1%1", "fd00::1", "::"] {
            #expect(IPAddress(text)?.isMulticastOrBroadcast == false, "\(text)")
        }
    }

    @Test func blockAllStillDropsAFlowWithNoName() throws {
        let blockAll = try snapshot(.blockAll)
        #expect(decide(flow(probe), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(flow(agent), blockAll) == .drop(reason: "no_host"))
        #expect(decide(flow(agent, port: 41641, tcp: false), blockAll) == .drop(reason: "no_host"))
        #expect(decide(flow(agent, port: 443), blockAll) == .readServerName)
        // Approvals count only in ask mode.
        #expect(decide(flow(probe), blockAll, context(approved: [key(probe, tailnet)])) == .drop(reason: "no_rule"))
    }

    @Test func anApprovalOfAnAddressCoversOnlyThatAddressWithNoName() throws {
        let ask = try snapshot(.ask)
        let approved = context(approved: [key(probe, tailnet), key(adHoc, "fd7a:115c:a1e0::1")],
                               answers: ["valensrv.example.ts.net": [tailnet]])
        #expect(decide(flow(probe), ask, approved) == .allow(reason: "approval;address"))
        // Any port, as for a host name; no lookup is made.
        #expect(decide(flow(probe, port: 2222), ask, approved) == .allow(reason: "approval;address"))
        #expect(decide(flow(adHoc, address: "fd7a:115c:a1e0::1"), ask, approved) == .allow(reason: "approval;address"))
        // Another address, another app, or another build: asked about.
        #expect(decide(flow(probe, address: "100.66.32.76"), ask, approved) == asked)
        #expect(decide(flow(agent), ask, approved) == asked)
        #expect(decide(flow(.adHoc(cdhash: String(repeating: "e", count: 40)), address: "fd7a:115c:a1e0::1"), ask, approved)
                == asked)
        // A connection with a name is asked about by its name, whatever its address.
        #expect(decide(flow(probe, "valensrv.example.ts.net"), ask, approved) == .ask(reason: "no_rule", addressMatches: true))
        #expect(decide(flow(probe, dnsNames: ["valensrv.example.ts.net"]), ask, approved)
                == .ask(reason: "no_rule", addressMatches: true))
        // On 443 the server name is read first, and a server name is judged as a name.
        #expect(decide(flow(probe, port: 443), ask, approved) == .readServerName)
        #expect(hello(.serverName("example.org"), flow(probe, port: 443), ask, approved) == .resolveHost("example.org"))
    }

    @Test func aHostNameThatIsTheAddressWrittenOutNamesNothing() throws {
        // URLSession attaches the URL's host, here the address itself, as the flow's host name.
        #expect(flow(probe, tailnet).hostname == nil)
        #expect(flow(probe, "fd7a:115c:a1e0:0::1", address: "fd7a:115c:a1e0::1").hostname == nil)
        #expect(flow(probe, "example.org").hostname == "example.org")
        let ask = try snapshot(.ask)
        #expect(decide(flow(probe, tailnet), ask) == asked)
        #expect(decide(flow(ssh, tailnet), try snapshot(.blockAll)) == .allow(reason: "rule_line_3;address"))
        // Another address written out is not this flow's: refused as before.
        #expect(flow(probe, "100.66.32.76").hostname == "100.66.32.76")
        #expect(decide(flow(probe, "100.66.32.76"), ask) == .drop(reason: "hostname_invalid"))
    }

    @Test func aHelloWithNoServerNameIsAskedAboutByItsAddress() throws {
        // curl https://100.66.32.75/ sends no server name: RFC 6066 has no place for an address.
        let ask = try snapshot(.ask)
        let bare = flow(probe, port: 443)
        #expect(hello(.deny("sni_missing"), bare, ask) == .ask(reason: "no_rule;address;sni_missing", addressMatches: true))
        #expect(hello(.deny("sni_missing"), bare, ask, context(approved: [key(probe, tailnet)]))
                == .allow(reason: "approval;address;sni_missing"))
        // Paused after its hello, the server is waiting: the short hold.
        #expect(FilterPolicy.holdLimit(bare, afterServerName: true) == FilterPolicy.connectedHoldSeconds)
        #expect(FilterPolicy.eventHost(bare, serverName: nil) == tailnet)
        // A flow that had a name and sends none in its hello is dropped, as before.
        #expect(hello(.deny("sni_missing"), flow(probe, "example.org", port: 443), ask) == .drop(reason: "sni_missing"))
        #expect(hello(.deny("sni_missing"), flow(probe, port: 443, dnsNames: ["example.org"]), ask)
                == .drop(reason: "sni_missing"))
        #expect(hello(.deny("sni_missing"), flow(probe, port: 443, address: "fe80::7"), ask)
                == .ask(reason: "no_rule;address;sni_missing", addressMatches: true))
        #expect(hello(.deny("sni_missing"), flow(.unresolved, port: 443), ask) == .drop(reason: "sni_missing"))
        // Block-all, and any other hello that cannot be read: dropped.
        #expect(hello(.deny("sni_missing"), bare, try snapshot(.blockAll)) == .drop(reason: "sni_missing"))
        #expect(hello(.deny("tls_unparsed"), bare, ask) == .drop(reason: "tls_unparsed"))
        #expect(hello(.deny("not_tls"), bare, ask) == .drop(reason: "not_tls"))
    }

    @Test func theEventNamesTheServerNameThenTheHostThenTheDNSNameThenTheAddress() {
        let facts = flow(probe, "API.Example.com", port: 443, dnsNames: ["dns.example.com"])
        #expect(FilterPolicy.eventHost(facts, serverName: "sni.example.com") == "sni.example.com")
        #expect(FilterPolicy.eventHost(facts, serverName: nil) == "api.example.com")
        #expect(FilterPolicy.eventHost(flow(probe, dnsNames: ["dns.example.com"]), serverName: nil) == "dns.example.com")
        #expect(FilterPolicy.eventHost(flow(probe), serverName: nil) == tailnet)
        #expect(FilterPolicy.eventHost(flow(probe, "bad host"), serverName: nil) == nil)
    }
}

struct AddressRulePolicyTests {
    @Test func anAddressEntryAllowsItsAddressesWithOrWithoutAName() throws {
        for mode in [Mode.blockAll, .ask] {
            let rules = try snapshot(mode)
            let allowed = FlowVerdict.allow(reason: "rule_line_3;address")
            let inside = ["100.64.0.0", tailnet, "100.127.255.255", "10.0.0.5", "fd7a:115c:a1e0::1",
                          "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff", "::ffff:100.64.0.1"]
            for address in inside {
                #expect(decide(flow(ssh, address: address), rules) == allowed, "\(mode) \(address)")
                #expect(decide(flow(ssh, port: 41641, tcp: false, address: address), rules) == allowed)
                // With a host name, any name: the address is what counts, and nothing is looked up.
                #expect(decide(flow(ssh, "valensrv.example.ts.net", address: address), rules) == allowed)
                #expect(decide(flow(ssh, "evil.example", address: address), rules) == allowed)
                // On 443 the server name is not read.
                #expect(decide(flow(ssh, "evil.example", port: 443, address: address), rules) == allowed)
                #expect(decide(flow(ssh, port: 443, address: address), rules) == allowed)
            }
            // A held flow (one decided before an address rule applied) is let through on its address.
            #expect(hello(.serverName("evil.example"), flow(ssh, port: 443), rules) == allowed)
            // Just outside each range: no address match, so the usual path.
            for address in ["100.63.255.255", "100.128.0.0", "10.0.0.4", "10.0.0.6", "fd7a:115c:a1e1::", "fd7a:115c:a1df::1"] {
                let expected = mode == .ask ? asked : .drop(reason: "no_host")
                #expect(decide(flow(ssh, address: address), rules) == expected, "\(mode) \(address)")
            }
            // Outside the ranges, a name entry still needs its address check.
            let outside = flow(ssh, "valensrv.example.ts.net", address: "198.51.100.1")
            #expect(decide(outside, rules) == .resolveHost("valensrv.example.ts.net"))
            #expect(decide(outside, rules, context(answers: ["valensrv.example.ts.net": ["198.51.100.1"]]))
                    == .allow(reason: "rule_line_3"))
            // Another app, or the same identifier from another team: not the rule's app.
            #expect(decide(flow(probe), rules) == (mode == .ask ? asked : .drop(reason: "no_rule")))
            #expect(decide(flow(signed("com.apple.ssh", "ZZZZZ99999")), rules) == (mode == .ask ? asked : .drop(reason: "no_rule")))
        }
        // Ad hoc code has no signing identity, so rules never name it.
        #expect(decide(flow(adHoc), try snapshot(.ask)) == asked)
        #expect(decide(flow(adHoc), try snapshot(.blockAll)) == .drop(reason: "adhoc_code"))
    }

    @Test func aRuleWithOnlyAddressesStillNamesItsApp() throws {
        let only = try ProviderConfiguration(generation: 7, mode: .blockAll, configText: """
            mode = "block-all"

            [[allow]]
            app = "com.valentorassa.blackice.probe"
            team = "ABCDE12345"
            hosts = ["192.168.1.0/24"]

            """)
        #expect(decide(flow(probe, address: "192.168.1.20"), only) == .allow(reason: "rule_line_3;address"))
        #expect(decide(flow(probe, address: "192.168.2.20"), only) == .drop(reason: "no_host"))
        // On 443 outside the range the server name is read, and no name entry covers it.
        #expect(decide(flow(probe, port: 443, address: "192.168.2.20"), only) == .readServerName)
        #expect(hello(.serverName("example.org"), flow(probe, port: 443, address: "192.168.2.20"), only)
                == .drop(reason: "no_rule"))
        #expect(decide(flow(probe, "example.org", address: "192.168.2.20"), only) == .drop(reason: "no_rule"))
    }
}

struct AddressTextTests {
    @Test func strictAddressesRefuseAmbiguousIPv4() {
        #expect(IPAddress.strict("100.66.32.75")?.description == "100.66.32.75")
        #expect(IPAddress.strict("0.0.0.0")?.description == "0.0.0.0")
        #expect(IPAddress.strict("255.255.255.255")?.description == "255.255.255.255")
        #expect(IPAddress.strict("FD7A:115C:A1E0::1")?.description == "fd7a:115c:a1e0::1")
        #expect(IPAddress.strict("::ffff:100.66.32.75")?.description == "100.66.32.75")
        #expect(IPAddress.strict("64:ff9b::198.51.100.4") != nil)
        let loopback = if_nametoindex("lo0")
        #expect(IPAddress.strict("fe80::1%lo0")?.description == "fe80::1%\(loopback)")
        // inet_pton takes the first two as 10.0.0.1; other parsers read 010 as octal.
        for text in ["010.0.0.1", "10.0.0.01", "10.1", "10.0.1", "127.1", "0x0a.0.0.1", "256.0.0.1", "1.2.3.4.5",
                     "1.2.3.", ".1.2.3", "1..2.3", "+1.2.3.4", " 1.2.3.4", "1.2.3.4 ", "1.2.3.4%en0", "::ffff:010.0.0.1",
                     "2001:db8::1%en0", "2001:db8::g", "2001:db8::1/64", "", "%", "fe80::1%", "example.com"] {
            #expect(IPAddress.strict(text) == nil, "\(text)")
        }
    }

    @Test func loopbackAddresses() {
        for text in ["127.0.0.1", "127.0.0.0", "127.255.255.255", "::1", "::ffff:127.0.0.1"] {
            #expect(IPAddress(text)?.isLoopback == true, "\(text)")
        }
        for text in ["126.255.255.255", "128.0.0.0", "::", "::2", "::127.0.0.1", "0.0.0.0", "fe80::1%1"] {
            #expect(IPAddress(text)?.isLoopback == false, "\(text)")
        }
    }

    @Test func destinationsAreHostNamesOrAddressesInOneSpelling() {
        let normal: [(String, String)] = [
            ("Example.COM.", "example.com"), (tailnet, tailnet),
            ("FD7A:115C:A1E0:0:0:0:0:1", "fd7a:115c:a1e0::1"), ("::ffff:100.66.32.75", tailnet),
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"), ("FE80::1", "fe80::1"),
        ]
        for (raw, expected) in normal {
            #expect(normalizeDestination(raw) == expected, "\(raw)")
            #expect(isNormalDestination(expected), "\(expected)")
        }
        // A link-local address with an interface is no destination: a flow's has none.
        for raw in ["fe80::1%lo0", "fe80::1%7", "010.0.0.1", "10.1", "1.2.3.4/32", "*.example.com", "2001:db8::1%en0",
                    "bad host", ""] {
            #expect(normalizeDestination(raw) == nil, "\(raw)")
        }
        for text in ["Example.com", "FD7A:115C:A1E0::1", "fd7a:115c:a1e0:0:0:0:0:1", "010.0.0.1", "fe80::1%7", "fe80::1%lo0",
                     "::ffff:100.66.32.75", "10.0.0.0/8", ""] {
            #expect(!isNormalDestination(text), "\(text)")
        }
        // The name of a flow's destination: the address, whatever interface it was read with.
        #expect(IPAddress("fe80::1%7")?.destination == "fe80::1" && IPAddress("fe80::1")?.destination == "fe80::1")
        #expect(IPAddress("FD7A:115C:A1E0::1")?.destination == "fd7a:115c:a1e0::1")
    }

    @Test func rangesHoldTheirAddressesAndNoOthers() throws {
        func range(_ text: String) throws -> AddressRange { try AddressRange.parse(text).get() }
        func holds(_ range: AddressRange, _ text: String) -> Bool { range.contains(IPAddress(text)!) }
        let cgnat = try range("100.64.0.0/10")
        #expect(cgnat.prefix == 10 && cgnat.network == [100, 64, 0, 0] && cgnat.canonical == "100.64.0.0/10")
        #expect(holds(cgnat, "100.64.0.0") && holds(cgnat, "100.127.255.255") && holds(cgnat, "::ffff:100.100.100.100"))
        // ::6440:1 is IPv6 (IPv4-compatible, not mapped), so outside an IPv4 range.
        #expect(!holds(cgnat, "100.63.255.255") && !holds(cgnat, "100.128.0.0") && !holds(cgnat, "::6440:1"))
        let top = try range("128.0.0.0/1")
        #expect(holds(top, "128.0.0.0") && holds(top, "255.255.255.255") && !holds(top, "127.255.255.255"))
        let pair = try range("10.0.0.4/31")
        #expect(holds(pair, "10.0.0.4") && holds(pair, "10.0.0.5") && !holds(pair, "10.0.0.6") && !holds(pair, "10.0.0.3"))
        let one = try range("10.0.0.5")
        #expect(one.prefix == 32 && holds(one, "10.0.0.5") && !holds(one, "10.0.0.4"))
        #expect(try range("10.0.0.5/32").canonical == one.canonical)
        let odd = try range("172.16.0.0/12")
        #expect(holds(odd, "172.31.255.255") && !holds(odd, "172.32.0.0") && !holds(odd, "172.15.255.255"))

        let tail = try range("FD7A:115C:A1E0::/48")
        #expect(tail.prefix == 48 && tail.canonical == "fd7a:115c:a1e0::/48")
        #expect(holds(tail, "fd7a:115c:a1e0::") && holds(tail, "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"))
        #expect(!holds(tail, "fd7a:115c:a1e1::") && !holds(tail, "fd7a:115c:a1df:ffff::1"))
        let last = try range("2001:db8::/127")
        #expect(holds(last, "2001:db8::") && holds(last, "2001:db8::1") && !holds(last, "2001:db8::2"))
        let host = try range("2001:db8::1")
        #expect(host.prefix == 128 && holds(host, "2001:db8::1") && !holds(host, "2001:db8::"))
        let half = try range("8000::/1")
        #expect(holds(half, "ffff::1") && holds(half, "8000::") && !holds(half, "7fff:ffff::"))
        // A rule names no interface: link-local entries hold the address on every link.
        let link = try range("fe80::/10")
        #expect(holds(link, "fe80::1%1") && holds(link, "fe80::1%2") && holds(link, "febf::1") && !holds(link, "fec0::1"))
        // Families never mix.
        let low = try range("::/1")
        #expect(holds(low, "2001:db8::1") && !holds(low, "10.0.0.1"))
        #expect(!holds(cgnat, "2001:db8::1"))
    }

    @Test func rangesInAnyOtherFormAreRefusedWithAReason() {
        let cases: [(String, AddressRange.Problem)] = [
            ("010.0.0.0/8", .notAnAddress), ("10.1/16", .notAnAddress), ("1.2.3", .notAnAddress), ("256.0.0.0/8", .notAnAddress),
            ("10.0.0.0/8/9", .prefix(maximum: 32)), ("10.0.0.0/", .prefix(maximum: 32)), ("10.0.0.0/08", .prefix(maximum: 32)),
            ("10.0.0.0/-1", .prefix(maximum: 32)), ("10.0.0.0/33", .prefix(maximum: 32)), ("10.0.0.0/+8", .prefix(maximum: 32)),
            ("2001:db8::/129", .prefix(maximum: 128)), ("2001:db8::/1000", .prefix(maximum: 128)),
            ("10.0.0.5/8", .hostBits(network: "10.0.0.0/8")), ("100.66.32.75/10", .hostBits(network: "100.64.0.0/10")),
            ("fd7a:115c:a1e0::1/48", .hostBits(network: "fd7a:115c:a1e0::/48")), ("10.0.0.5/31", .hostBits(network: "10.0.0.4/31")),
            ("0.0.0.0/0", .everything), ("::/0", .everything), ("10.0.0.0/0", .everything),
            ("fe80::1%en0", .zone), ("fe80::/10%en0", .zone), ("::ffff:10.0.0.0/104", .mapped), ("::ffff:10.0.0.5", .mapped),
        ]
        for (text, problem) in cases {
            #expect(AddressRange.parse(text) == .failure(problem), "\(text)")
        }
        // What is read as an address rather than a host name.
        for text in ["10.0.0.5", "10.1", "1.2.3.4.5", "::1", "fe80::1%en0", "10.0.0.0/8", "/8", "a/b"] {
            #expect(AddressRange.looksLikeAddress(text), "\(text)")
        }
        for text in ["example.com", "*.ts.net", "0x0a.0.0.1", "1.example", ""] {
            #expect(!AddressRange.looksLikeAddress(text), "\(text)")
        }
    }
}

struct AddressMessageTests {
    private func event(host: String?, ip: String) -> HookEvent {
        HookEvent(id: "ev-0a1b2c3d", token: testToken,
                  app: .init(signingID: "com.apple.ssh", teamID: nil, path: "/usr/bin/ssh"),
                  host: host, ip: ip, port: 22, deadline: Date().addingTimeInterval(10))
    }

    @Test func anEventMayNameItsAddressAsItsHost() throws {
        try event(host: tailnet, ip: tailnet).validate(now: Date())
        try event(host: "fd7a:115c:a1e0::1", ip: "fd7a:115c:a1e0::1").validate(now: Date())
        // A link-local address has no interface in an event.
        try event(host: "fe80::1", ip: "fe80::1").validate(now: Date())
        let link = "fe80::1%\(if_nametoindex("lo0"))"
        let bad = [
            event(host: tailnet, ip: "203.0.113.7"), event(host: "100.66.32.76", ip: tailnet),
            event(host: "FD7A:115C:A1E0::1", ip: "fd7a:115c:a1e0::1"), event(host: link, ip: link),
            event(host: "010.0.0.1", ip: "10.0.0.1"), event(host: "100.64.0.0/10", ip: tailnet),
        ]
        for candidate in bad {
            #expect(throws: MessageError.self, "\(candidate.host ?? "nil")") { try candidate.validate(now: Date()) }
        }
        // The daemon answers for that address.
        let request = try #require(Daemon.request(.approve(seconds: 3600), for: event(host: tailnet, ip: tailnet)))
        #expect(request == AnswerRequest(kind: .approve, app: .signed(SigningIdentity(signingID: "com.apple.ssh", teamID: nil)),
                                         host: tailnet, seconds: 3600, token: testToken))
        try request.validate(now: Date())
    }

    /// The eval's events with an address as the host must stay in the format the daemon sends.
    @Test(arguments: ["14", "21", "22", "23", "36", "37"])
    func evalAddressEventsValidate(_ id: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("integrations/eval/events/\(id).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // run.sh adds the deadline; the daemon holds the token.
        object["token"] = testToken
        object["deadline"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        #expect(object["id"] as? String == "ev-" + String(format: "%08x", try #require(Int(id))))
        let decoded = try HookEvent.decode(JSONSerialization.data(withJSONObject: object))
        try decoded.validate(now: Date())
        #expect(decoded.host == decoded.ip)
    }

    @Test func answersAndPendingRepliesTakeAnAddress() throws {
        let ssh = AppIdentity.signed(SigningIdentity(signingID: "com.apple.ssh", teamID: nil))
        try AnswerRequest(kind: .approve, app: ssh, host: tailnet, seconds: 60, token: nil).validate(now: Date())
        try AnswerRequest(kind: .deny, app: ssh, host: "fd7a:115c:a1e0::1", seconds: nil, token: nil).validate(now: Date())
        try AnswerRequest(kind: .approve, app: ssh, host: "fe80::1", seconds: 60, token: nil).validate(now: Date())
        for host in ["010.0.0.1", "100.64.0.0/10", "fe80::1%7", "FD7A::1", "::ffff:100.66.32.75"] {
            #expect(throws: MessageError.self, "\(host)") {
                try AnswerRequest(kind: .deny, app: ssh, host: host, seconds: nil, token: nil).validate(now: Date())
            }
        }
        let summary = { (host: String, ip: String) in
            PendingReply(events: [PendingSummary(id: "ev-0a1b2c3d", app: AppReference(ssh), path: nil, host: host, ip: ip,
                                                 port: 22, secondsLeft: 5, connections: 1)],
                         approvals: [ApprovalSummary(app: AppReference(ssh), host: tailnet, secondsLeft: 60)])
        }
        try summary(tailnet, tailnet).validate(now: Date())
        #expect(throws: MessageError.self) { try summary(tailnet, "203.0.113.7").validate(now: Date()) }
    }
}

struct AddressApprovalTests {
    private let ssh = AppIdentity.signed(SigningIdentity(signingID: "com.apple.ssh", teamID: nil))

    @Test func anApprovalOfAnAddressReleasesTheConnectionsWaitingOnIt() throws {
        var ask = AskState<String>()
        var tokens: [String: String] = [:]
        for (name, host, port) in [("ssh", tailnet, UInt16(22)), ("mosh", tailnet, 60001), ("other", "100.66.32.76", 22)] {
            let key = PendingKey(identity: ssh, host: host, port: port)
            let added = ask.pending.add(name, key: key, addressMatches: true, now: 0, timeout: 30) { seconds in
                try HookEvent.connection(app: .init(self.ssh, path: "/usr/bin/ssh"), host: host, ip: host, port: port,
                                         deadline: Date().addingTimeInterval(seconds))
            }
            if case .raised(let event) = added { tokens[name] = event.token }
        }
        // The daemon's answer for the event, with its token.
        let outcome = ask.answer(AnswerRequest(kind: .approve, app: ssh, host: tailnet, seconds: 3600, token: tokens["ssh"]),
                                 now: 1)
        #expect(outcome.reply.status == .done)
        #expect(Set(outcome.released.map(\.flow)) == ["ssh", "mosh"] && outcome.released.allSatisfy(\.allow))
        #expect(ask.approvals.covers(ApprovalKey(identity: ssh, host: tailnet), now: 3600))
        #expect(!ask.approvals.covers(ApprovalKey(identity: ssh, host: "100.66.32.76"), now: 2))
        #expect(ask.pending.eventCount == 1)
        // A person's deny of the other address.
        let denied = ask.answer(AnswerRequest(kind: .deny, app: ssh, host: "100.66.32.76", seconds: nil, token: nil), now: 2)
        #expect(denied.released.map(\.flow) == ["other"] && !denied.released[0].allow)
        // An address in another spelling is not an answer.
        let odd = ask.answer(AnswerRequest(kind: .deny, app: ssh, host: "100.066.32.75", seconds: nil, token: nil), now: 3)
        #expect(odd.reply.reason == "invalid_request")
    }
}
