import Foundation
import Testing
@testable import BlackiceCore

// The built-in table of macOS services, and the two ways around per-host rules: that table and
// [[allow]] rules with hosts = ["*"].

/// Code that runs commands or fetches URLs for someone else. None of it may be in the table.
/// Identifiers read with `codesign -dv` on macOS 27.0.1.
private let generalPurpose = [
    "com.apple.curl", "com.apple.nscurl", "com.apple.python3", "com.apple.perl", "com.apple.perl5", "com.apple.ruby",
    "com.apple.bash", "com.apple.zsh", "com.apple.sh", "com.apple.dash", "com.apple.ksh", "com.apple.csh",
    "com.apple.ssh", "com.apple.scp", "com.apple.sftp", "com.apple.ssh-keyscan", "com.apple.nc", "com.apple.git",
    "com.apple.osascript", "com.apple.jsc", "com.apple.swift-frontend", "com.apple.dt.xcode_select.tool-shim-public",
    "com.apple.rsync", "com.apple.openssl", "com.apple.tftp", "com.apple.smbutil", "com.apple.automatorCLI",
    "com.apple.shortcuts.ShortcutsCommandLine", "com.apple.Terminal", "com.tcltk.tclsh",
    "com.apple.Safari", "com.apple.WebKit.Networking", "com.apple.WebKit.WebContent", "com.apple.nsurlsessiond",
    // Resolves names for every app; its own port-53 flows have a separate exemption.
    "com.apple.mDNSResponder",
]

/// Apple's own domains. Only the certificate services may list others.
private let appleDomains = ["apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "cdn-apple.com",
                            "mzstatic.com", "aaplimg.com", "apple-dns.net", "ls4-apple.com.akadns.net"]
private let certificateServices: Set = ["com.apple.trustd", "com.apple.ocspd"]

struct AppleServicesTableTests {
    @Test func entriesAreWellFormed() {
        let ids = AppleServices.entries.map(\.signingID)
        #expect(Set(ids).count == ids.count, "duplicate signing identifiers")
        #expect(ids == ids.sorted())
        #expect(AppleServices.table.count == ids.count)
        for (id, hosts) in AppleServices.entries {
            #expect(validSigningID(id) && id.hasPrefix("com.apple."), "\(id)")
            #expect(!hosts.isEmpty, "\(id)")
            // Every pattern compiles, and none is listed twice.
            let patterns = AppleServices.table[id] ?? []
            #expect(patterns.count == hosts.count, "\(id) has a pattern that is not a host or *.domain")
            #expect(Set(patterns.map(\.source)).count == hosts.count, "\(id) lists a pattern twice")
        }
        #expect(Set(AppleServices.certificateHosts).count == AppleServices.certificateHosts.count)
    }

    @Test func generalPurposeToolsAreNeverCovered() {
        for id in generalPurpose {
            #expect(AppleServices.table[id] == nil, "\(id) is in the table")
            #expect(!AppleServices.covers(SigningIdentity(signingID: id, teamID: nil)), "\(id)")
        }
        #expect(!AppleServices.entries.contains { $0.signingID.lowercased().contains("curl") })
    }

    @Test func hostsStayOnApplesDomainsExceptForCertificateChecks() {
        for (id, patterns) in AppleServices.table {
            for pattern in patterns {
                let host = pattern.wildcard ? String(pattern.suffix.dropFirst()) : pattern.suffix
                let apple = appleDomains.contains { host == $0 || host.hasSuffix("." + $0) }
                if certificateServices.contains(id) {
                    #expect(apple || AppleServices.certificateHosts.contains(pattern.source), "\(id): \(pattern.source)")
                } else {
                    #expect(apple, "\(id) may reach \(pattern.source), outside Apple's domains")
                }
            }
        }
    }

    @Test func onlyApplePlatformCodeMatches() {
        let cloudd = SigningIdentity(signingID: "com.apple.cloudd", teamID: nil)
        #expect(AppleServices.covers(cloudd))
        #expect(AppleServices.allows(cloudd, host: "gateway.icloud.com"))
        #expect(AppleServices.allows(cloudd, host: "p01-ckdatabase.icloud.com"))
        #expect(!AppleServices.allows(cloudd, host: "icloud.com"))
        #expect(!AppleServices.allows(cloudd, host: "example.org"))
        #expect(!AppleServices.allows(cloudd, host: "gateway.icloud.com.example.org"))
        // The same identifier with a Team ID is someone else's code, and so are Apple's
        // Command Line Tools, which carry Apple's Team ID rather than none.
        for team in ["ABCDE12345", "59GAB85EFG"] {
            let other = SigningIdentity(signingID: "com.apple.cloudd", teamID: team)
            #expect(!AppleServices.covers(other) && !AppleServices.allows(other, host: "gateway.icloud.com"))
        }
        let trustd = SigningIdentity(signingID: "com.apple.trustd", teamID: nil)
        for host in ["ocsp.apple.com", "valid.apple.com", "ocsp.digicert.com", "crl3.digicert.com", "r10.c.lencr.org",
                     "o.pki.goog", "pki.goog", "ocsp.sectigo.com"] {
            #expect(AppleServices.allows(trustd, host: host), "\(host)")
        }
        #expect(!AppleServices.allows(trustd, host: "evil.example"))
        #expect(!AppleServices.allows(trustd, host: "goog"))
    }

    /// Seen asking in the 0.3.0 runs. codesign's timestamp service gets its one host and nothing
    /// else, and the contacts sync only iCloud, as dataaccessd does.
    @Test func servicesSeenInTheZeroThreeRuns() {
        let timestamp = SigningIdentity(signingID: "com.apple.security.XPCTimeStampingService", teamID: nil)
        #expect(AppleServices.allows(timestamp, host: "timestamp.apple.com"))
        #expect(!AppleServices.allows(timestamp, host: "www.apple.com"))
        #expect(!AppleServices.allows(SigningIdentity(signingID: timestamp.signingID, teamID: "ABCDE12345"),
                                      host: "timestamp.apple.com"))
        let contacts = SigningIdentity(signingID: "com.apple.AddressBookSourceSync", teamID: nil)
        #expect(AppleServices.allows(contacts, host: "p404-contacts.icloud.com"))
        #expect(!AppleServices.allows(contacts, host: "www.googleapis.com"))
        let media = SigningIdentity(signingID: "com.apple.amsengagementd", teamID: nil)
        for host in ["amp-api.media.apple.com", "bag.itunes.apple.com", "apps.mzstatic.com"] {
            #expect(AppleServices.allows(media, host: host), "\(host)")
        }
        let categories = SigningIdentity(signingID: "com.apple.ctcategories.service", teamID: nil)
        #expect(AppleServices.allows(categories, host: "amp-api.apps.apple.com"))
        #expect(!AppleServices.allows(categories, host: "example.org"))
    }
}

// MARK: - The policy

/// Lines: 3 for the agent, 8 for Tailscale's `*` rule, 13 for a rule naming one iCloud host for cloudd.
/// Line 2 is free for `apple_services`.
private func servicesRules(_ line2: String = "") -> String {
    """
    mode = "block-all"
    \(line2)
    [[allow]]
    app = "com.example.agent"
    team = "ABCDE12345"
    hosts = ["api.example.com"]

    [[allow]]
    app = "io.tailscale.ipn.macsys.network-extension"
    team = "W5364U7YZB"
    hosts = ["*"]

    [[allow]]
    app = "com.apple.cloudd"
    hosts = ["gateway.icloud.com"]
    """
}

private func snapshot(_ mode: Mode, _ line2: String = "") throws -> ProviderConfiguration {
    try ProviderConfiguration(generation: 3, mode: mode, configText: servicesRules(line2))
}

private func signed(_ id: String, _ team: String?) -> IdentityResolution {
    .verified(SigningIdentity(signingID: id, teamID: team))
}

private let agent = signed("com.example.agent", "ABCDE12345")
private let probe = signed("com.valentorassa.blackice.probe", "ABCDE12345")
private let cloudd = signed("com.apple.cloudd", nil)
private let fakeCloudd = signed("com.apple.cloudd", "ABCDE12345")
private let apsd = signed("com.apple.apsd", nil)
private let trustd = signed("com.apple.trustd", nil)
private let curl = signed("com.apple.curl", nil)
private let tailscale = signed("io.tailscale.ipn.macsys.network-extension", "W5364U7YZB")
private let address = "17.248.1.1"

private func flow(_ identity: IdentityResolution, _ host: String?, port: UInt16? = 443, tcp: Bool = true,
                  address: String? = address) -> FlowFacts {
    FlowFacts(direction: .outbound, identity: identity, internetSocket: true, tcp: tcp, hostname: host, port: port,
              remoteAddress: address.flatMap(IPAddress.init))
}

private func answering(_ check: AddressCheck) -> PolicyContext {
    PolicyContext(approved: { _, _ in false }, address: { _, _ in check })
}
private var matching: PolicyContext { answering(.match) }
private var mismatching: PolicyContext { answering(.mismatch) }
/// Nothing looked up yet: any host check would ask for a lookup first.
private var unknown: PolicyContext { answering(.unknown) }

private func decide(_ facts: FlowFacts, _ snapshot: ProviderConfiguration, _ context: PolicyContext = matching) -> FlowVerdict {
    FilterPolicy.decide(facts, snapshot: snapshot, context: context)
}

struct AppleServicesPolicyTests {
    @Test func blockAllAllowsApplePlatformServicesToTheirHosts() throws {
        let blockAll = try snapshot(.blockAll)
        let cases: [(FlowFacts, FlowVerdict)] = [
            (flow(cloudd, "p01-ckdatabase.icloud.com"), .allow(reason: "apple_service")),
            (flow(cloudd, "cvws.icloud-content.com", port: 8443), .allow(reason: "apple_service")),
            // A rule that names the host comes first.
            (flow(cloudd, "gateway.icloud.com"), .allow(reason: "rule_line_13")),
            (flow(cloudd, "example.org"), .drop(reason: "no_rule")),
            // The same signing identifier with a Team ID is not Apple's code.
            (flow(fakeCloudd, "p01-ckdatabase.icloud.com"), .drop(reason: "no_rule")),
            (flow(fakeCloudd, "gateway.icloud.com"), .drop(reason: "no_rule")),
            (flow(apsd, "12-courier.push.apple.com", port: 5223), .allow(reason: "apple_service")),
            (flow(apsd, "www.apple.com"), .drop(reason: "no_rule")),
            (flow(trustd, "ocsp.digicert.com", port: 80), .allow(reason: "apple_service")),
            (flow(trustd, "evil.example", port: 80), .drop(reason: "no_rule")),
            // curl and the other general-purpose tools are not covered, even to Apple's hosts.
            (flow(curl, "gateway.icloud.com"), .drop(reason: "no_rule")),
            (flow(curl, "www.apple.com"), .drop(reason: "no_rule")),
            (flow(signed("com.apple.nsurlsessiond", nil), "www.apple.com"), .drop(reason: "no_rule")),
            (flow(signed("com.apple.Safari", nil), "www.apple.com"), .drop(reason: "no_rule")),
            // No host name: block-all reads the TLS server name for a covered service, as for a rule.
            (flow(apsd, nil), .readServerName),
            (flow(apsd, nil, tcp: false), .drop(reason: "no_host")),
            (flow(curl, nil), .drop(reason: "no_rule")),
            (flow(fakeCloudd, nil), .drop(reason: "no_rule")),
        ]
        for (facts, expected) in cases {
            #expect(decide(facts, blockAll) == expected, "\(facts)")
        }
        for id in generalPurpose {
            #expect(decide(flow(signed(id, nil), "gateway.icloud.com"), blockAll) == .drop(reason: "no_rule"), "\(id)")
        }
    }

    @Test func theAddressIsCheckedLikeARule() throws {
        let blockAll = try snapshot(.blockAll)
        let facts = flow(cloudd, "p01-ckdatabase.icloud.com")
        #expect(decide(facts, blockAll, unknown) == .resolveHost("p01-ckdatabase.icloud.com"))
        #expect(decide(facts, blockAll, mismatching) == .drop(reason: "address_mismatch"))
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com", address: nil), blockAll) == .drop(reason: "no_address"))
        let ask = try snapshot(.ask)
        #expect(decide(facts, ask, mismatching) == .ask(reason: "address_mismatch", addressMatches: false))
    }

    @Test func serverNameOfAHeldServiceFlow() throws {
        let blockAll = try snapshot(.blockAll)
        let held = flow(apsd, nil)
        #expect(FilterPolicy.decide(held, serverName: .serverName("1-courier.push.apple.com"), snapshot: blockAll, context: matching)
            == .allow(reason: "apple_service;server_name"))
        #expect(FilterPolicy.decide(held, serverName: .serverName("evil.example"), snapshot: blockAll, context: matching)
            == .drop(reason: "no_rule"))
    }

    @Test func askModeDoesNotAskAboutCoveredServices() throws {
        let ask = try snapshot(.ask)
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com"), ask) == .allow(reason: "apple_service"))
        #expect(decide(flow(fakeCloudd, "p01-ckdatabase.icloud.com"), ask) == .ask(reason: "no_rule", addressMatches: true))
        #expect(decide(flow(curl, "gateway.icloud.com"), ask) == .ask(reason: "no_rule", addressMatches: true))
        #expect(decide(flow(cloudd, "example.org"), ask) == .ask(reason: "no_rule", addressMatches: true))
    }

    @Test func appleServicesFalseTurnsTheTableOff() throws {
        let blockAll = try snapshot(.blockAll, "apple_services = false")
        #expect(!blockAll.config.appleServices)
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com"), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(flow(apsd, "12-courier.push.apple.com"), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(flow(apsd, nil), blockAll) == .drop(reason: "no_rule"))
        // Rules still count.
        #expect(decide(flow(cloudd, "gateway.icloud.com"), blockAll) == .allow(reason: "rule_line_13"))
        #expect(decide(flow(cloudd, nil), blockAll) == .readServerName)
        let ask = try snapshot(.ask, "apple_services = false")
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com"), ask) == .ask(reason: "no_rule", addressMatches: true))
        // Written out as true, it is the default.
        let explicit = try snapshot(.blockAll, "apple_services = true")
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com"), explicit) == .allow(reason: "apple_service"))
    }

    @Test func acceptAllIsUnchanged() throws {
        let acceptAll = try snapshot(.acceptAll)
        #expect(decide(flow(cloudd, "p01-ckdatabase.icloud.com"), acceptAll) == .allow(reason: "accept_all"))
        #expect(decide(flow(curl, nil), acceptAll) == .allow(reason: "accept_all"))
    }
}

struct AnyHostRulePolicyTests {
    @Test func aStarRuleAllowsEverythingItsAppDoesInBlockAllAndAsk() throws {
        for mode in [Mode.blockAll, .ask] {
            let rules = try snapshot(mode)
            // Nothing is looked up (the context would answer resolveHost) and no TLS is read.
            let cases: [FlowFacts] = [
                // Tailscale's DNS proxy forwarding a lookup to 100.100.100.100, by address.
                flow(tailscale, nil, port: 53, tcp: false, address: "100.100.100.100"),
                flow(tailscale, nil, port: 41641, tcp: false, address: "198.51.100.20"),
                flow(tailscale, nil, port: 443, address: "198.51.100.20"),
                flow(tailscale, "derp11e.tailscale.com"),
                flow(tailscale, "derp11e.tailscale.com", address: nil),
                flow(tailscale, nil, port: nil, address: nil),
                flow(tailscale, "bad host"),
            ]
            for facts in cases {
                #expect(decide(facts, rules, unknown) == .allow(reason: "rule_line_8"), "\(mode) \(facts)")
                #expect(decide(facts, rules, mismatching) == .allow(reason: "rule_line_8"), "\(mode) \(facts)")
            }
            #expect(FilterPolicy.decide(flow(tailscale, nil), serverName: .serverName("anything.example"),
                                        snapshot: rules, context: unknown) == .allow(reason: "rule_line_8"))
        }
    }

    @Test func aStarRuleForAnotherAppDoesNotApply() throws {
        let blockAll = try snapshot(.blockAll)
        let ask = try snapshot(.ask)
        let dns = { (identity: IdentityResolution) in flow(identity, nil, port: 53, tcp: false, address: "100.100.100.100") }
        // Same signing identifier, another team or none.
        for impostor in [signed("io.tailscale.ipn.macsys.network-extension", "ZZZZZ99999"),
                         signed("io.tailscale.ipn.macsys.network-extension", nil)] {
            #expect(decide(dns(impostor), blockAll) == .drop(reason: "no_rule"))
            #expect(decide(dns(impostor), ask) == .drop(reason: "no_host"))
            #expect(decide(flow(impostor, "derp11e.tailscale.com"), blockAll) == .drop(reason: "no_rule"))
        }
        // Other apps keep their own rules and checks.
        #expect(decide(dns(agent), blockAll) == .drop(reason: "no_host"))
        #expect(decide(dns(probe), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(dns(probe), ask) == .drop(reason: "no_host"))
        #expect(decide(flow(agent, "api.example.com"), blockAll, mismatching) == .drop(reason: "address_mismatch"))
        #expect(decide(flow(.adHoc(cdhash: testCDHash), nil, port: 53, tcp: false), ask) == .drop(reason: "no_host"))
    }

    @Test func aStarRuleDoesNotDependOnAppleServices() throws {
        let blockAll = try snapshot(.blockAll, "apple_services = false")
        #expect(decide(flow(tailscale, nil, port: 53, tcp: false), blockAll, unknown) == .allow(reason: "rule_line_8"))
        #expect(decide(flow(tailscale, nil), try snapshot(.acceptAll)) == .allow(reason: "accept_all"))
    }
}
