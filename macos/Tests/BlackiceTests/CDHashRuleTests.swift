import Foundation
import Testing
@testable import BlackiceCore

// [[allow]] rules that name ad hoc code by its cdhash, and the interpreters they never count for.
// Rule lines: 3 for gh, 7 for uv's python, 11 for a tunnel tool by address, 15 for a tool with
// `*`, 19 for a signed agent.
private let gh = "8fbec897bc4d2bf005bff3945dc800000ded2752"
private let python = "1d0c9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d"
private let tunnel = "0e4570869fc8b963a4527bd5bd9b8ef5afc79fe5"
private let anywhere = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"

private let cdhashRules = """
mode = "block-all"

[[allow]]
cdhash = "\(gh)"
hosts = ["api.github.com"]

[[allow]]
cdhash = "\(python)"
hosts = ["oauth2.googleapis.com"]

[[allow]]
cdhash = "\(tunnel)"
hosts = ["100.64.0.0/10"]

[[allow]]
cdhash = "\(anywhere)"
hosts = ["*"]

[[allow]]
app = "com.example.agent"
team = "ABCDE12345"
hosts = ["api.github.com"]

"""

private func snapshot(_ mode: Mode) throws -> ProviderConfiguration {
    try ProviderConfiguration(generation: 7, mode: mode, configText: cdhashRules)
}

private let ghPath = "/opt/homebrew/Cellar/gh/2.103.3/bin/gh"
private let pythonPath = "/Users/me/.local/share/uv/python/cpython-3.14.0-macos-aarch64-none/bin/python3.14"
private let flowAddress = "203.0.113.7"

private func flow(_ cdhash: String, _ host: String?, path: String? = ghPath, port: UInt16? = 443, tcp: Bool = true,
                  address: String? = flowAddress, dnsNames: Set<String> = []) -> FlowFacts {
    FlowFacts(direction: .outbound, identity: .adHoc(cdhash: cdhash), internetSocket: true, tcp: tcp, hostname: host,
              port: port, remoteAddress: address.flatMap(IPAddress.init), dnsNames: dnsNames, executablePath: path)
}

private func signedFlow(_ id: String, _ team: String?, _ host: String?, port: UInt16? = 443) -> FlowFacts {
    FlowFacts(direction: .outbound, identity: .verified(SigningIdentity(signingID: id, teamID: team)), internetSocket: true,
              tcp: true, hostname: host, port: port, remoteAddress: IPAddress(flowAddress))
}

/// Approvals by cdhash and host, and every host resolving to the flow's address unless `address` says otherwise.
private func context(approved: Set<ApprovalKey> = [], address: AddressCheck = .match) -> PolicyContext {
    PolicyContext(approved: { approved.contains(ApprovalKey(identity: $0, host: $1)) }, address: { _, _ in address })
}

private func decide(_ facts: FlowFacts, _ snapshot: ProviderConfiguration,
                    _ context: PolicyContext = context()) -> FlowVerdict {
    FilterPolicy.decide(facts, snapshot: snapshot, context: context)
}

private func hello(_ name: String, _ facts: FlowFacts, _ snapshot: ProviderConfiguration,
                   _ context: PolicyContext = context()) -> FlowVerdict {
    FilterPolicy.decide(facts, serverName: .serverName(name), snapshot: snapshot, context: context)
}

private let asked = FlowVerdict.ask(reason: "no_rule", addressMatches: true)

struct CDHashRuleTests {
    @Test func aCDHashRuleAllowsItsBuildInBlockAllAndAsk() throws {
        for mode in [Mode.blockAll, .ask] {
            let rules = try snapshot(mode)
            // On the TLS port the server name is read first, as for any host rule.
            #expect(decide(flow(gh, "api.github.com"), rules) == .readServerName, "\(mode)")
            #expect(hello("api.github.com", flow(gh, "api.github.com"), rules) == .allow(reason: "rule_line_3;server_name"))
            #expect(hello("api.github.com", flow(gh, nil), rules) == .allow(reason: "rule_line_3;server_name"))
            #expect(decide(flow(gh, "API.GitHub.com.", port: 8443), rules) == .allow(reason: "rule_line_3"))
            #expect(decide(flow(gh, "api.github.com", tcp: false), rules) == .allow(reason: "rule_line_3"))
            // The one name DNS answers gave the address counts as for signed code.
            #expect(decide(flow(gh, nil, port: 8443, dnsNames: ["api.github.com"]), rules)
                == .allow(reason: "rule_line_3;dns_name"))
            // Address entries and `*` work as in any rule.
            #expect(decide(flow(tunnel, nil, port: 22, address: "100.66.32.75"), rules) == .allow(reason: "rule_line_11;address"))
            #expect(decide(flow(anywhere, nil, port: 5000, tcp: false), rules) == .allow(reason: "rule_line_15"))
            #expect(hello("example.org", flow(anywhere, "api.github.com"), rules) == .allow(reason: "rule_line_15"))
        }
    }

    @Test func itNamesOnlyThatBuild() throws {
        let blockAll = try snapshot(.blockAll)
        let ask = try snapshot(.ask)
        // A host the rule does not name: block-all drops it as for signed code, ask mode asks.
        #expect(decide(flow(gh, "uploads.github.com"), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(flow(gh, "uploads.github.com"), ask) == asked)
        #expect(hello("uploads.github.com", flow(gh, "api.github.com"), blockAll) == .drop(reason: "server_name_mismatch"))
        #expect(decide(flow(gh, nil, port: 22), blockAll) == .drop(reason: "no_host"))
        #expect(decide(flow(tunnel, nil, port: 22, address: "198.51.100.9"), blockAll) == .drop(reason: "no_host"))
        // An upgrade or a rebuild has another cdhash: no rule names it, and block-all drops it as before.
        let rebuilt = String(repeating: "e", count: 40)
        #expect(decide(flow(rebuilt, "api.github.com"), blockAll) == .drop(reason: "adhoc_code"))
        #expect(hello("api.github.com", flow(rebuilt, nil), blockAll) == .drop(reason: "adhoc_code"))
        #expect(decide(flow(rebuilt, "api.github.com"), ask) == asked)
        #expect(decide(flow(rebuilt, nil, port: 22, address: "100.66.32.75"), blockAll) == .drop(reason: "adhoc_code"))
        // Signed code never matches a cdhash rule, even with the cdhash as its signing identifier, and the
        // signed agent's rule for the same host does not cover ad hoc code.
        #expect(decide(signedFlow(gh, nil, "api.github.com", port: 8443), blockAll) == .drop(reason: "no_rule"))
        #expect(decide(signedFlow("com.example.agent", "ABCDE12345", "api.github.com", port: 8443), blockAll)
            == .allow(reason: "rule_line_19"))
        #expect(decide(signedFlow("com.example.agent", "ABCDE12345", "example.org", port: 5000), blockAll) == .drop(reason: "no_rule"))
    }

    @Test func theHostAndAddressCheckStillApplies() throws {
        for mode in [Mode.blockAll, .ask] {
            let rules = try snapshot(mode)
            let facts = flow(gh, "api.github.com", port: 8443)
            #expect(decide(facts, rules, context(address: .unknown)) == .resolveHost("api.github.com"), "\(mode)")
            #expect(decide(flow(gh, "api.github.com", address: nil), rules) == .drop(reason: "no_address"))
            let mismatch = decide(facts, rules, context(address: .mismatch))
            let expected = mode == .blockAll ? FlowVerdict.drop(reason: "address_mismatch")
                : FlowVerdict.ask(reason: "address_mismatch", addressMatches: false)
            #expect(mismatch == expected)
        }
    }

    @Test func aCDHashRuleNeverCountsForAnInterpreter() throws {
        let blockAll = try snapshot(.blockAll)
        let ask = try snapshot(.ask)
        let script = flow(python, "oauth2.googleapis.com", path: pythonPath)
        // Decided as if the rule were not there, and the reason says why.
        #expect(decide(script, blockAll) == .drop(reason: "adhoc_code;interpreter"))
        #expect(decide(flow(python, "oauth2.googleapis.com", path: pythonPath, port: 8443), blockAll)
            == .drop(reason: "adhoc_code;interpreter"))
        #expect(hello("oauth2.googleapis.com", flow(python, nil, path: pythonPath), blockAll)
            == .drop(reason: "adhoc_code;interpreter"))
        #expect(decide(script, ask) == .ask(reason: "no_rule;interpreter", addressMatches: true))
        #expect(hello("oauth2.googleapis.com", flow(python, nil, path: pythonPath), ask)
            == .ask(reason: "no_rule;interpreter", addressMatches: true))
        #expect(decide(flow(python, nil, path: pythonPath, port: 8443, dnsNames: ["oauth2.googleapis.com"]), ask)
            == .ask(reason: "no_rule;interpreter", addressMatches: true))
        // An approval of the interpreter's cdhash still counts: the owner's choice, for at most 24 hours.
        let approved = context(approved: [ApprovalKey(identity: .cdhash(python), host: "oauth2.googleapis.com")])
        #expect(decide(flow(python, "oauth2.googleapis.com", path: pythonPath, port: 8443), ask, approved)
            == .allow(reason: "approval;interpreter"))
        #expect(decide(script, ask, approved) == .readServerName)
        #expect(hello("oauth2.googleapis.com", script, ask, approved) == .allow(reason: "approval;server_name;interpreter"))
        // Whatever the rule's hosts: `*`, an address entry, another name.
        #expect(decide(flow(anywhere, "example.org", path: "/opt/homebrew/bin/node"), blockAll)
            == .drop(reason: "adhoc_code;interpreter"))
        #expect(decide(flow(tunnel, nil, path: "/bin/zsh", port: 22, address: "100.66.32.75"), ask)
            == .ask(reason: "no_rule;address;interpreter", addressMatches: true))
        #expect(FilterPolicy.decide(flow(tunnel, nil, path: "/bin/zsh", address: "100.66.32.75"), serverName: .deny("sni_missing"),
                                    snapshot: ask, context: context())
            == .ask(reason: "no_rule;address;sni_missing;interpreter", addressMatches: true))
        // The framework build of Python runs as Python.app/Contents/MacOS/Python.
        let framework = "/opt/homebrew/Cellar/python@3.14/3.14.0/Frameworks/Python.framework/Versions/3.14/Resources/" +
            "Python.app/Contents/MacOS/Python"
        #expect(decide(flow(python, "oauth2.googleapis.com", path: framework), blockAll) == .drop(reason: "adhoc_code;interpreter"))
        // With no path from the kernel there is nothing to tell an interpreter by, so the rule does not count either.
        #expect(decide(flow(gh, "api.github.com", path: nil), blockAll) == .drop(reason: "adhoc_code;no_path"))
        #expect(decide(flow(gh, "api.github.com", path: nil), ask) == .ask(reason: "no_rule;no_path", addressMatches: true))
        // An interpreter no rule names keeps the reasons it had.
        let other = String(repeating: "b", count: 40)
        #expect(decide(flow(other, "example.org", path: pythonPath), blockAll) == .drop(reason: "adhoc_code"))
        #expect(decide(flow(other, "example.org", path: pythonPath), ask) == asked)
        // What the name does not stop: the same interpreter under another name has the same cdhash, so a rule
        // that names an interpreter's cdhash matches the renamed copy.
        #expect(decide(flow(python, "oauth2.googleapis.com", path: "/Users/me/bin/gcloud-helper", port: 8443), blockAll)
            == .allow(reason: "rule_line_7"))
    }

    @Test func interpretersAreToldByTheExecutablesName() {
        let interpreters = [
            "python", "python2", "python3", "python3.14", "python3.14t", "pythonw", "Python", "node", "nodejs", "node22",
            "bun", "deno", "ruby", "ruby3.3", "perl", "perl5", "perl5.34", "perl5.30.3", "php", "php8.3", "lua", "lua5.4",
            "luajit", "luajit-2.1.0-beta3", "tclsh", "tclsh8.6", "wish", "wish8.6", "Rscript", "R", "julia", "julia-1.11",
            "osascript", "sh", "bash", "bash5.2", "zsh", "dash", "ksh", "tcsh", "csh", "fish", "pwsh", "PYTHON3_12",
        ]
        for name in interpreters {
            #expect(Interpreters.contains(path: "/opt/homebrew/bin/" + name), "\(name)")
        }
        #expect(Interpreters.contains(path: pythonPath) && Interpreters.contains(path: "python3"))
        let tools = [
            "gh", "stripe", "terraform", "ssh", "mosh", "docker", "r2", "R2", "rg", "uv", "go", "cargo", "git", "node-gyp",
            "python-config", "pythonista", "ipython", "rbash", "php-fpm", "bunx", "shx", "zshdb", "python3 ", "pythön", "",
        ]
        for name in tools {
            #expect(!Interpreters.contains(path: "/opt/homebrew/bin/" + name), "\(name)")
        }
        // Only the file name counts, not the folders it is in.
        #expect(!Interpreters.contains(path: "/opt/python3.14/bin/gh") && !Interpreters.contains(path: "/usr/local/node/bin/terraform"))
    }

    @Test func dryRunAndConfigurationChange() throws {
        let acceptAll = try ProviderConfiguration(generation: 7, mode: .acceptAll, configText: cdhashRules)
        #expect(FilterPolicy.dryRun(flow(gh, "api.github.com"), snapshot: acceptAll) == "rule_line_3;server_name")
        #expect(FilterPolicy.dryRun(flow(gh, "api.github.com", port: 8443), snapshot: acceptAll) == "rule_line_3")
        #expect(FilterPolicy.dryRun(flow(gh, "uploads.github.com"), snapshot: acceptAll) == "ask")
        #expect(FilterPolicy.dryRun(flow(python, "oauth2.googleapis.com", path: pythonPath), snapshot: acceptAll) == "ask")
        #expect(FilterPolicy.dryRun(flow(python, nil, path: pythonPath, port: 5353, tcp: false), snapshot: acceptAll)
            == "drop:no_host;interpreter")
        // A flow held under ask mode when block-all is installed: the rule lets its build go on, not the interpreter.
        let blockAll = try snapshot(.blockAll)
        let changed = { (facts: FlowFacts, serverName: String?) in
            FilterPolicy.afterChange(facts, serverName: serverName, echPresent: false, snapshot: blockAll,
                                     address: { _, _ in .match })
        }
        #expect(changed(flow(gh, "api.github.com", port: 8443), nil) == .allow(reason: "rule_line_3;configuration_changed"))
        #expect(changed(flow(gh, "api.github.com"), "api.github.com")
            == .allow(reason: "rule_line_3;server_name;configuration_changed"))
        #expect(changed(flow(python, "oauth2.googleapis.com", path: pythonPath, port: 8443), nil)
            == .drop(reason: "configuration_changed"))
    }

    @Test func theLogLineSaysWhy() throws {
        let line = FlowLogLine(flow: flow(python, "oauth2.googleapis.com", path: pythonPath),
                               verdict: .drop(reason: "adhoc_code;interpreter"), snapshot: try snapshot(.blockAll))
        #expect(line.publicText == "drop adhoc_code;interpreter app=cdhash/" + python)
    }
}
