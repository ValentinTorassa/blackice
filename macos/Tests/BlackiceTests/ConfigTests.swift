import Foundation
import Testing
@testable import BlackiceCore

private let example = """
# blackice.toml
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 10    # no answer in time means deny

# Permanent rules. Checked before anything is asked.
[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]

[[hook]]
on = "connection"
program = "/Users/me/.local/bin/fx"
app = "com.vercel.fx"
team = "JW6Y669B67"
args = ["ask", "--no-save", "--no-color", "Use the blackice skill to decide whether to approve the pending connection"]
env = ["HOME=/Users/me/.config/blackice/agent", "FX_DISABLE_KEYCHAIN=1"]
"""

/// The error a document produces, or nil if it parses.
private func error(_ text: String) -> ConfigError? {
    do {
        _ = try BlackiceConfig(text: text)
        return nil
    } catch let error as ConfigError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
        return nil
    }
}

private func expectError(_ text: String, line: Int?, containing fragment: String,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    guard let failure = error(text) else {
        Issue.record("expected an error containing \(fragment)", sourceLocation: sourceLocation)
        return
    }
    #expect(failure.line == line, "line of: \(failure)", sourceLocation: sourceLocation)
    #expect(failure.message.contains(fragment), "message: \(failure.message)", sourceLocation: sourceLocation)
}

struct ConfigParsingTests {
    @Test func readsTheDocumentedExample() throws {
        let config = try BlackiceConfig(text: example)
        #expect(config.mode == .ask)
        #expect(config.timeoutSeconds == 10)
        #expect(config.allow.count == 1)
        #expect(config.allow[0].app == "com.example.agent")
        #expect(config.allow[0].team == "ABCDE12345")
        #expect(config.allow[0].hosts.map(\.source) == ["api.example.com"])
        #expect(config.allow[0].line == 6)
        #expect(config.hooks == [Hook(on: "connection", program: HookProgram(
            path: "/Users/me/.local/bin/fx",
            arguments: ["ask", "--no-save", "--no-color", "Use the blackice skill to decide whether to approve the pending connection"],
            environment: ["HOME": "/Users/me/.config/blackice/agent", "FX_DISABLE_KEYCHAIN": "1"],
            identity: SigningIdentity(signingID: "com.vercel.fx", teamID: "JW6Y669B67")), line: 11)])
        #expect(config.summary == "mode ask, timeout 10 s, 1 allow rule, 1 hook")
    }

    @Test func exampleFileInTheRepositoryIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/blackice.toml")
        let config = try BlackiceConfig(data: Data(contentsOf: url))
        #expect(config.mode == .ask && config.allow.count == 2 && config.hooks.count == 1)
        #expect(config.loopback && config.allow[1].addresses.map(\.prefix) == [10, 48])
    }

    @Test func minimalDocumentUsesDefaults() throws {
        let config = try BlackiceConfig(text: "mode = \"block-all\"")
        #expect(config.mode == .blockAll)
        #expect(config.timeoutSeconds == BlackiceConfig.defaultTimeoutSeconds)
        #expect(config.allow.isEmpty && config.hooks.isEmpty)
        #expect(config.summary == "mode block-all, timeout 10 s, 0 allow rules, 0 hooks")
    }

    @Test(arguments: Mode.allCases)
    func everyModeParses(_ mode: Mode) throws {
        #expect(try BlackiceConfig(text: "mode = '\(mode.rawValue)'").mode == mode)
    }

    @Test func layoutVariantsTOMLAllows() throws {
        let text = "\t  mode   =   \"accept-all\"  \r\n" +
            "  [[allow]]   # a comment after a header\r\n" +
            "  app = 'com.apple.curl'\r\n" +
            "  hosts = [\r\n" +
            "    \"example.com\",   # one\r\n" +
            "    # a comment line inside the array\r\n" +
            "    '*.example.org',\r\n" +
            "  ]\r\n" +
            "# the end, with no newline"
        let config = try BlackiceConfig(text: text)
        #expect(config.mode == .acceptAll)
        #expect(config.allow[0].team == nil)
        #expect(config.allow[0].hosts.map(\.source) == ["example.com", "*.example.org"])
    }

    @Test func basicStringEscapes() throws {
        let config = try BlackiceConfig(text: #"mode = "\u0061sk""# + "\n[[hook]]\non = \"connection\"\nrun = \"say \\\"hi\\\" \\\\ \\U0001F600\"")
        #expect(config.mode == .ask)
        #expect(config.hooks[0].run == "say \"hi\" \\ 😀")
    }

    @Test func literalStringsKeepBackslashes() throws {
        let config = try BlackiceConfig(text: "mode = 'ask'\n[[hook]]\non = 'connection'\nrun = 'C:\\path \\n'")
        #expect(config.hooks[0].run == "C:\\path \\n")
    }

    @Test func severalRulesAndHooksKeepTheirOrder() throws {
        let text = """
        mode = "ask"
        [[allow]]
        app = "com.one"
        team = "AAAAAAAAAA"
        hosts = ["one.example"]
        [[hook]]
        on = "connection"
        run = "first"
        [[allow]]
        app = "com.two"
        team = "BBBBBBBBBB"
        hosts = ["two.example"]
        [[hook]]
        on = "connection"
        run = "second"
        """
        let config = try BlackiceConfig(text: text)
        #expect(config.allow.map(\.app) == ["com.one", "com.two"])
        #expect(config.allow.map(\.line) == [2, 9])
        #expect(config.hooks.map(\.run) == ["first", "second"])
    }

    @Test func appleServicesIsOnByDefaultAndCanBeTurnedOff() throws {
        #expect(try BlackiceConfig(text: "mode = 'ask'").appleServices)
        #expect(try BlackiceConfig(text: "mode = 'ask'\napple_services = true").appleServices)
        let off = try BlackiceConfig(text: "mode = 'ask'\napple_services = false # strict")
        #expect(!off.appleServices)
        #expect(off.summary == "mode ask, timeout 10 s, 0 allow rules, 0 hooks, apple_services off")
        #expect(try BlackiceConfig(text: "apple_services = false\nmode = 'block-all'").appleServices == false)
    }

    @Test func loopbackIsAllowedByDefaultAndCanBeFiltered() throws {
        #expect(try BlackiceConfig(text: "mode = 'ask'").loopback)
        #expect(try BlackiceConfig(text: "mode = 'ask'\nloopback = true").loopback)
        let off = try BlackiceConfig(text: "mode = 'ask'\nloopback = false")
        #expect(!off.loopback)
        #expect(off.summary == "mode ask, timeout 10 s, 0 allow rules, 0 hooks, loopback off")
        #expect(try BlackiceConfig(text: "mode = 'ask'").summary == "mode ask, timeout 10 s, 0 allow rules, 0 hooks")
        expectError("mode = 'ask'\nloopback = \"false\"", line: 2, containing: "loopback must be true or false, not a string")
        expectError("mode = 'ask'\nloopback = 0", line: 2, containing: "loopback must be true or false, not an integer")
        expectError("mode = 'ask'\nloopback = true\nloopback = false", line: 3,
                    containing: "duplicate key 'loopback' at the top level (first set on line 2)")
        expectError("mode = 'ask'\n[[allow]]\napp = 'com.a'\nhosts = ['a.example']\nloopback = false", line: 5,
                    containing: "unknown key 'loopback' in [[allow]]; top-level keys go before the first table")
    }

    @Test func hostsTakeAddressesAndRangesNextToNames() throws {
        let config = try BlackiceConfig(text: """
        mode = "ask"
        [[allow]]
        app = "com.apple.ssh"
        hosts = ["100.64.0.0/10", "10.0.0.5", "fd7a:115c:a1e0::/48", "*.ts.net", "2001:DB8::1"]
        """)
        let rule = try #require(config.allow.first)
        #expect(rule.hosts.map(\.source) == ["*.ts.net"])
        #expect(rule.addresses.map(\.source) == ["100.64.0.0/10", "10.0.0.5", "fd7a:115c:a1e0::/48", "2001:DB8::1"])
        #expect(rule.addresses.map(\.prefix) == [10, 32, 48, 128])
        #expect(!rule.anyHost)
        let ssh = SigningIdentity(signingID: "com.apple.ssh", teamID: nil)
        #expect(config.addressRule(for: ssh, address: IPAddress("100.66.32.75")!)?.line == 2)
        #expect(config.addressRule(for: ssh, address: IPAddress("2001:db8::1")!)?.line == 2)
        #expect(config.addressRule(for: ssh, address: IPAddress("10.0.0.6")!) == nil)
        #expect(config.addressRule(for: SigningIdentity(signingID: "com.apple.ssh", teamID: "ABCDE12345"),
                                   address: IPAddress("100.66.32.75")!) == nil)
        // Address entries name no host, and name entries no address.
        #expect(config.allowRule(for: ssh, host: "100.66.32.75") == nil)
        #expect(config.allowRule(for: ssh, host: "valensrv.example.ts.net")?.line == 2)
        // Other spellings TOML and the strict reader take.
        for entry in ["'10.0.0.0/8'", "\"255.255.255.255/32\"", "'0.0.0.0'", "'::1'", "'fe80::/10'", "'2001:db8::1/128'",
                      "'64:ff9b::198.51.100.4'", "'1.2.3.4/32'"] {
            #expect(throws: Never.self, "\(entry)") {
                _ = try BlackiceConfig(text: "mode = 'ask'\n[[allow]]\napp = 'com.a'\nhosts = [\(entry)]")
            }
        }
    }

    @Test func addressEntriesAreReadStrictly() {
        let head = "mode = 'ask'\n[[allow]]\napp = 'com.a'\nhosts = "
        let cases: [(String, String)] = [
            ("['010.0.0.1']", "no leading zeros"),
            ("['10.1']", "is not an IP address or a CIDR range"),
            ("['1.2.3.4.5']", "is not an IP address or a CIDR range"),
            ("['256.1.1.1']", "is not an IP address or a CIDR range"),
            ("['0x0a.0.0.1']", "is not a host name, a *.domain pattern, an IP address or a CIDR range"),
            ("['10.0.0.0/33']", "the prefix of \"10.0.0.0/33\" must be a number from 1 to 32"),
            ("['2001:db8::/129']", "must be a number from 1 to 128"),
            ("['10.0.0.0/']", "must be a number from 1 to 32"),
            ("['10.0.0.0/08']", "must be a number from 1 to 32"),
            ("['10.0.0.5/8']", "\"10.0.0.5/8\" has bits set after its prefix; write \"10.0.0.0/8\""),
            ("['fd7a:115c:a1e0::1/48']", "write \"fd7a:115c:a1e0::/48\""),
            ("['0.0.0.0/0']", "covers every address; write hosts = [\"*\"] for any destination"),
            ("['::/0']", "covers every address"),
            ("['fe80::1%en0']", "names an interface"),
            ("['::ffff:10.0.0.0/104']", "IPv4-mapped IPv6 address; write the IPv4 address"),
            ("['10.0.0.0/8', '10.0.0.0/8']", "\"10.0.0.0/8\" appears twice in hosts"),
            ("['10.0.0.5', '10.0.0.5/32']", "\"10.0.0.5/32\" appears twice in hosts"),
            ("['2001:db8::1', '2001:DB8:0::1']", "appears twice in hosts"),
            ("['*', '10.0.0.5']", "\"*\" must be the only entry in hosts"),
            ("['10.0.0.5', '*']", "\"*\" must be the only entry in hosts"),
        ]
        for (hosts, fragment) in cases {
            expectError(head + hosts, line: 4, containing: fragment)
        }
        // The limit on entries counts addresses too.
        let tooMany = "[" + (0...BlackiceConfig.maximumHostsPerRule).map { "'10.0.\($0 / 256).\($0 % 256)'" }
            .joined(separator: ",") + "]"
        expectError(head + tooMany, line: 4, containing: "more than 256 entries")
        let mixed = "[" + (0..<BlackiceConfig.maximumHostsPerRule).map { $0 % 2 == 0 ? "'10.0.0.\($0)'" : "'h\($0).example'" }
            .joined(separator: ",") + "]"
        #expect(throws: Never.self) { _ = try BlackiceConfig(text: head + mixed) }
    }

    @Test func starAloneAllowsAnyHost() throws {
        let config = try BlackiceConfig(text: """
        mode = "block-all"
        [[allow]]
        app = "io.tailscale.ipn.macsys.network-extension"
        team = "W5364U7YZB"
        hosts = ["*"]
        [[allow]]
        app = "com.example.agent"
        team = "ABCDE12345"
        hosts = ["api.example.com"]
        """)
        let tailscale = SigningIdentity(signingID: "io.tailscale.ipn.macsys.network-extension", teamID: "W5364U7YZB")
        let rule = try #require(config.allow.first)
        #expect(rule.anyHost && rule.hosts.isEmpty && rule.line == 2)
        #expect(config.anyHostRule(for: tailscale)?.line == 2)
        // It names no host, so per-host lookups do not return it.
        #expect(config.allowRule(for: tailscale, host: "derp11e.tailscale.com") == nil)
        #expect(config.anyHostRule(for: SigningIdentity(signingID: "io.tailscale.ipn.macsys.network-extension", teamID: "ZZZZZ99999")) == nil)
        #expect(config.anyHostRule(for: SigningIdentity(signingID: "io.tailscale.ipn.macsys.network-extension", teamID: nil)) == nil)
        #expect(config.anyHostRule(for: SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345")) == nil)
        #expect(!config.allow[1].anyHost)
        // Literal strings too.
        #expect(try BlackiceConfig(text: "mode = 'ask'\n[[allow]]\napp = 'com.a'\nteam = 'ABCDE12345'\nhosts = [ '*' ]").allow[0].anyHost)
    }

    @Test func timeoutBounds() throws {
        #expect(try BlackiceConfig(text: "mode = 'ask'\ntimeout_seconds = 1").timeoutSeconds == 1)
        #expect(try BlackiceConfig(text: "mode = 'ask'\ntimeout_seconds = 120").timeoutSeconds == 120)
        expectError("mode = 'ask'\ntimeout_seconds = 0", line: 2, containing: "between 1 and 120")
        expectError("mode = 'ask'\ntimeout_seconds = 121", line: 2, containing: "between 1 and 120")
    }
}

struct ConfigRejectionTests {
    @Test func wholeFileProblems() {
        expectError("", line: nil, containing: "empty")
        expectError("# only a comment\n", line: nil, containing: "missing required key 'mode'")
        expectError("mode = 'ask'" + String(repeating: " ", count: BlackiceConfig.maximumBytes), line: nil, containing: "larger than 64 KiB")
        #expect(throws: ConfigError(line: nil, "the file is not valid UTF-8")) {
            try BlackiceConfig(data: Data([0x6D, 0x6F, 0x64, 0x65, 0x20, 0x3D, 0x20, 0x22, 0xC3, 0x28, 0x22]))
        }
        #expect(throws: ConfigError(line: 1, "byte order marks are not supported")) {
            try BlackiceConfig(data: Data([0xEF, 0xBB, 0xBF] + Array("mode = 'ask'".utf8)))
        }
    }

    @Test func fileAtTheSizeLimitIsRead() throws {
        let base = "mode = 'ask'\n"
        let padded = base + "#" + String(repeating: "x", count: BlackiceConfig.maximumBytes - base.utf8.count - 1)
        #expect(padded.utf8.count == BlackiceConfig.maximumBytes)
        #expect(try BlackiceConfig(text: padded).mode == .ask)
    }

    @Test func wrongModeAndTypes() {
        expectError("mode = \"allow-all\"", line: 1, containing: "mode must be")
        expectError("mode = \"ASK\"", line: 1, containing: "mode must be")
        expectError("mode = ask", line: 1, containing: "strings need quotes")
        expectError("mode = 1", line: 1, containing: "mode must be a string, not an integer")
        expectError("mode = true", line: 1, containing: "mode must be a string, not a boolean")
        expectError("mode = ['ask']", line: 1, containing: "mode must be a string, not an array")
        expectError("mode = 'ask'\ntimeout_seconds = \"10\"", line: 2, containing: "must be an integer, not a string")
        expectError("mode = 'ask'\napple_services = \"false\"", line: 2, containing: "apple_services must be true or false, not a string")
        expectError("mode = 'ask'\napple_services = 0", line: 2, containing: "apple_services must be true or false, not an integer")
        expectError("mode = 'ask'\napple_services = [false]", line: 2, containing: "apple_services must be true or false, not an array")
        expectError("mode = 'ask'\napple_services = False", line: 2, containing: "strings need quotes")
        expectError("mode = 'ask'\napple_services = no", line: 2, containing: "strings need quotes")
    }

    @Test(arguments: ["10.0", "1e3", "0x10", "0o17", "0b1", "+10", "-10", "1_000", "010", "inf", "nan", "1979-05-27", "07:32:00", "1234567890"])
    func unsupportedNumbers(_ number: String) {
        guard let failure = error("mode = 'ask'\ntimeout_seconds = \(number)") else {
            Issue.record("\(number) must be refused")
            return
        }
        #expect(failure.line == 2)
    }

    @Test func unknownAndDuplicateKeys() {
        expectError("mode = 'ask'\nmod = 'ask'", line: 2, containing: "unknown key 'mod' at the top level")
        expectError("mode = 'ask'\nmode = 'block-all'", line: 2, containing: "duplicate key 'mode' at the top level (first set on line 1)")
        expectError("mode = 'ask'\n[[allow]]\napp = 'com.a'\napp = 'com.b'\nhosts = ['a.example']", line: 4, containing: "duplicate key 'app' in [[allow]]")
        expectError("mode = 'ask'\n[[allow]]\napp = 'com.a'\nhost = ['a.example']", line: 4, containing: "unknown key 'host' in [[allow]]")
        expectError("mode = 'ask'\n[[hook]]\non = 'connection'\nrun = 'x'\ncommand = 'y'", line: 5, containing: "unknown key 'command' in [[hook]]")
        expectError("[[allow]]\napp = 'com.a'\nhosts = ['a.example']\nmode = 'ask'", line: 4, containing: "top-level keys go before the first table")
        expectError("mode = 'ask'\napple_services = true\napple_services = false", line: 3,
                    containing: "duplicate key 'apple_services' at the top level (first set on line 2)")
        expectError("mode = 'ask'\n[[allow]]\napp = 'com.a'\nhosts = ['a.example']\napple_services = false", line: 5,
                    containing: "unknown key 'apple_services' in [[allow]]; top-level keys go before the first table")
        expectError("mode = 'ask'\napple_service = false", line: 2, containing: "unknown key 'apple_service' at the top level")
    }

    @Test func unsupportedSyntax() {
        expectError("mode.x = 'ask'", line: 1, containing: "dotted keys are not supported")
        expectError("\"mode\" = 'ask'", line: 1, containing: "quoted keys are not supported")
        expectError("'mode' = 'ask'", line: 1, containing: "quoted keys are not supported")
        expectError("mode = 'ask'\n[allow]", line: 2, containing: "[allow] needs double brackets")
        expectError("mode = 'ask'\n[rules]", line: 2, containing: "unknown table [rules]")
        expectError("mode = 'ask'\n[[agent]]", line: 2, containing: "write [agent], not [[agent]]")
        expectError("mode = 'ask'\n[agent.x]", line: 2, containing: "dotted table names")
        expectError("mode = 'ask'\n[[allow.extra]]", line: 2, containing: "dotted table names")
        expectError("mode = 'ask'\n[[rules]]", line: 2, containing: "unknown table [[rules]]")
        expectError("mode = 'ask'\n[[allow]", line: 2, containing: "expected ']]'")
        expectError("mode = 'ask'\n[ [allow] ]", line: 2, containing: "expected [agent], [[allow]] or [[hook]]")
        expectError("mode = { value = 'ask' }", line: 1, containing: "inline tables")
        expectError("mode = \"\"\"ask\"\"\"", line: 1, containing: "multi-line strings")
        expectError("mode = '''ask'''", line: 1, containing: "multi-line strings")
        expectError("mode = 'ask'\n[[allow]]\napp = 'com.a'\nhosts = [['a.example']]", line: 4, containing: "nested arrays")
        expectError("mode 'ask'", line: 1, containing: "expected '='")
        expectError("mode =", line: 1, containing: "expected a value")
        expectError("= 'ask'", line: 1, containing: "expected a key")
        expectError("mode = 'ask' 'again'", line: 1, containing: "unexpected text after the value")
        expectError("mode = 'ask'\n[[allow]] trailing", line: 2, containing: "unexpected text")
    }

    @Test func brokenStrings() {
        expectError("mode = \"ask", line: 1, containing: "unterminated string")
        expectError("mode = 'ask\n'", line: 1, containing: "unterminated string")
        expectError("mode = \"a\\qsk\"", line: 1, containing: "invalid escape")
        expectError("mode = \"\\uD800\"", line: 1, containing: "invalid escape")
        expectError("mode = \"\\U00110000\"", line: 1, containing: "invalid escape")
        expectError("mode = \"\\u12\"", line: 1, containing: "invalid escape")
        expectError("mode = \"a\u{7}sk\"", line: 1, containing: "control character in string")
        expectError("mode = 'a\u{1B}sk'", line: 1, containing: "control character in string")
        expectError("mode = 'ask'\nteam\u{0}= 'x'", line: 2, containing: "expected '='")
        expectError("mode = 'ask' # bell \u{7}", line: 1, containing: "control character in comment")
        expectError("mode = 'ask'\r", line: 1, containing: "carriage return")
        expectError("\u{0}mode = 'ask'", line: 1, containing: "control character outside a string")
    }

    @Test func brokenArrays() {
        let head = "mode = 'ask'\n[[allow]]\napp = 'com.a'\n"
        expectError(head + "hosts = ['a.example'", line: 4, containing: "unterminated array")
        expectError(head + "hosts = ['a.example' 'b.example']", line: 4, containing: "expected ',' or ']'")
        expectError(head + "hosts = [,]", line: 4, containing: "expected a value")
        expectError(head + "hosts = [\n'a.example',\n", line: 6, containing: "unterminated array")
        let many = "[" + Array(repeating: "'a.example'", count: 1025).joined(separator: ",") + "]"
        expectError(head + "hosts = " + many, line: 4, containing: "more than 1024 items")
    }

    @Test func allowRuleChecks() {
        let head = "mode = 'ask'\n[[allow]]\n"
        expectError(head + "hosts = ['a.example']", line: 2, containing: "needs an 'app' key")
        expectError(head + "app = 'com.a'", line: 2, containing: "needs a 'hosts' key")
        expectError(head + "app = 'com.a\" or true'\nhosts = ['a.example']", line: 3, containing: "signing identifier")
        expectError(head + "app = 'com.a'\nteam = 'abcde12345'\nhosts = ['a.example']", line: 4, containing: "Team ID")
        expectError(head + "app = 'com.a'\nteam = 'ABCDE12345\" OR true'\nhosts = ['a.example']", line: 4, containing: "Team ID")
        expectError(head + "app = 'com.a'\nhosts = []", line: 4, containing: "must not be empty")
        expectError(head + "app = 'com.a'\nhosts = 'a.example'", line: 4, containing: "array of strings, not a string")
        expectError(head + "app = 'com.a'\nhosts = ['a.example', 7]", line: 4, containing: "holds an integer")
        expectError(head + "app = 'com.a'\nhosts = ['1.2.3']", line: 4, containing: "not an IP address or a CIDR range")
        expectError(head + "app = 'com.a'\nhosts = ['*', 'a.example']", line: 4, containing: "\"*\" must be the only entry in hosts")
        expectError(head + "app = 'com.a'\nhosts = ['a.example', '*']", line: 4, containing: "\"*\" must be the only entry in hosts")
        expectError(head + "app = 'com.a'\nhosts = ['*', '*']", line: 4, containing: "\"*\" must be the only entry in hosts")
        expectError(head + "app = 'com.a'\nhosts = ['*', 7]", line: 4, containing: "\"*\" must be the only entry in hosts")
        expectError(head + "app = 'com.a'\nhosts = ['**']", line: 4, containing: "not a host name")
        expectError(head + "app = 'com.a'\nhosts = ['*.']", line: 4, containing: "not a host name")
        expectError(head + "app = 'com.a'\nhosts = [' *']", line: 4, containing: "not a host name")
        expectError(head + "app = 'com.a'\nhosts = '*'", line: 4, containing: "array of strings, not a string")
        expectError(head + "app = 'com.a'\nhosts = ['a.example', 'A.Example.']", line: 4, containing: "appears twice")
        let tooMany = "[" + (0...BlackiceConfig.maximumHostsPerRule).map { "'h\($0).example'" }.joined(separator: ",") + "]"
        expectError(head + "app = 'com.a'\nhosts = " + tooMany, line: 4, containing: "more than 256 entries")
    }

    @Test func hookChecks() {
        let head = "mode = 'ask'\n[[hook]]\n"
        expectError(head + "run = 'x'", line: 2, containing: "needs an 'on' key")
        expectError(head + "on = 'connection'", line: 2, containing: "needs a 'program' or a 'run' key")
        expectError(head + "on = 'dns'\nrun = 'x'", line: 3, containing: "on must be \"connection\"")
        expectError(head + "on = 'connection'\nrun = '   '", line: 4, containing: "must not be empty")
        expectError(head + "on = 'connection'\nrun = \"line one\\nline two\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = \"esc \\u001b[31m\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = \"c1 \\u0085\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = '" + String(repeating: "x", count: 4097) + "'", line: 4, containing: "longer than 4096 bytes")
    }

    @Test func aProgramHook() throws {
        let config = try BlackiceConfig(text: """
        mode = "ask"

        [[hook]]
        on = "connection"
        program = "/Users/Jane Doe/.local/bin/fx"
        app = "com.vercel.fx"
        team = "JW6Y669B67"
        args = ["ask", "--no-save",
                "Use the blackice skill to decide whether to approve the pending connection"]
        env = ["HOME=/Users/Jane Doe/.config/blackice/agent", "FX_DISABLE_KEYCHAIN=1", "EMPTY=", "A=b=c"]

        [[hook]]
        on = "connection"
        program = "/bin/sh"
        app = "com.apple.sh"
        stdin = "none"
        """)
        #expect(config.hooks == [
            Hook(program: HookProgram(
                path: "/Users/Jane Doe/.local/bin/fx",
                arguments: ["ask", "--no-save", "Use the blackice skill to decide whether to approve the pending connection"],
                environment: ["HOME": "/Users/Jane Doe/.config/blackice/agent", "FX_DISABLE_KEYCHAIN": "1", "EMPTY": "", "A": "b=c"],
                identity: SigningIdentity(signingID: "com.vercel.fx", teamID: "JW6Y669B67")), line: 3),
            // No team: Apple platform code, as in [[allow]].
            Hook(program: HookProgram(path: "/bin/sh", identity: SigningIdentity(signingID: "com.apple.sh", teamID: nil),
                                      eventOnStdin: false), line: 12),
        ])
        #expect(config.hooks[0].run == nil && config.hooks[1].commandText == "/bin/sh")
        #expect(config.hooks[0].program?.eventOnStdin == true)
        #expect(config.hooks[0].commandText.hasPrefix("/Users/Jane Doe/.local/bin/fx ask --no-save Use the blackice skill"))
    }

    @Test func programHookChecks() {
        let head = "mode = 'ask'\n[[hook]]\non = 'connection'\n"
        let fx = head + "program = '/opt/fx'\napp = 'com.vercel.fx'\n"
        expectError(head + "program = '/opt/fx'\nrun = 'fx'\napp = 'com.vercel.fx'", line: 5, containing: "'program' or 'run', not both")
        expectError(head + "program = '/opt/fx'", line: 2, containing: "with program needs an 'app' key")
        expectError(head + "program = 'fx'\napp = 'com.vercel.fx'", line: 4, containing: "must be an absolute path")
        expectError(head + "program = \"/opt/f\\nx\"\napp = 'com.vercel.fx'", line: 4, containing: "must be an absolute path")
        expectError(head + "program = '/opt/fx'\napp = 'com vercel'", line: 5, containing: "signing identifier")
        expectError(fx + "team = 'jw6y669b67'", line: 6, containing: "Team ID")
        expectError(fx + "args = 'ask'", line: 6, containing: "args must be an array of strings")
        expectError(fx + "args = ['ask', 1]", line: 6, containing: "holds an integer")
        expectError(fx + "args = [\"a\\u0000b\"]", line: 6, containing: "no control characters")
        expectError(fx + "args = [" + Array(repeating: "'a'", count: 65).joined(separator: ",") + "]", line: 6,
                    containing: "more than 64 entries")
        expectError(fx + "env = ['HOME']", line: 6, containing: "NAME=value")
        expectError(fx + "env = ['=x']", line: 6, containing: "not a variable name")
        expectError(fx + "env = ['1A=x']", line: 6, containing: "not a variable name")
        expectError(fx + "env = ['A B=x']", line: 6, containing: "not a variable name")
        expectError(fx + "env = ['BLACKICE_EVENT_FILE=/tmp/x']", line: 6, containing: "BLACKICE_ is the daemon's")
        expectError(fx + "env = ['A=1', 'A=2']", line: 6, containing: "A is set twice")
        expectError(fx + "stdin = 'file'", line: 6, containing: "stdin must be \"event\" or \"none\"")
        expectError(fx + "stdin = false", line: 6, containing: "stdin")
        for key in ["args = ['x']", "env = ['A=1']", "app = 'com.a'", "team = 'ABCDE12345'", "stdin = 'none'"] {
            expectError(head + "run = 'x'\n" + key, line: 5, containing: "goes with program, not run")
        }
    }

    @Test func tableCountLimits() {
        let rule = "[[allow]]\napp = 'com.a'\nhosts = ['a.example']\n"
        let rules = "mode = 'ask'\n" + String(repeating: rule, count: BlackiceConfig.maximumAllowRules + 1)
        expectError(rules, line: 2 + BlackiceConfig.maximumAllowRules * 3, containing: "more than 256 [[allow]] rules")
        let hook = "[[hook]]\non = 'connection'\nrun = 'x'\n"
        let hooks = "mode = 'ask'\n" + String(repeating: hook, count: BlackiceConfig.maximumHooks + 1)
        expectError(hooks, line: 2 + BlackiceConfig.maximumHooks * 3, containing: "more than 8 [[hook]] tables")
    }

    @Test func agentNotes() throws {
        let config = try BlackiceConfig(text: """
        mode = "ask"

        [agent]
        notes = \"\"\"
        I use the AWS CLI from Homebrew's python for work.
        \tDeny analytics hosts, such as "stats.example.com".
        Quotes at the end: ""\"\"\"
        """)
        #expect(config.agentNotes == """
        I use the AWS CLI from Homebrew's python for work.
        \tDeny analytics hosts, such as "stats.example.com".
        Quotes at the end: ""
        """)
        #expect(config.summary.hasSuffix(", notes for the agent"))

        // Literal strings take no escapes, CRLF reads as LF, and the line after the closing quotes still parses.
        let literal = try BlackiceConfig(text: "mode = 'ask'\r\n[agent]\r\nnotes = '''\r\nC:\\path\r\nnext'''\r\n[[allow]]\r\n"
                                         + "app = 'com.a'\r\nhosts = ['a.example']\r\n")
        #expect(literal.agentNotes == "C:\\path\nnext")
        #expect(literal.allow.count == 1)

        #expect(try BlackiceConfig(text: "mode = 'ask'\n[agent]\nnotes = 'one line'").agentNotes == "one line")
        #expect(try BlackiceConfig(text: "mode = 'ask'\n[agent]\nnotes = \"\"\"\n  \n\"\"\"").agentNotes == nil)
        #expect(try BlackiceConfig(text: "mode = 'ask'\n[agent]").agentNotes == nil)
        #expect(try BlackiceConfig(text: "mode = 'ask'").agentNotes == nil)
        #expect(!(try BlackiceConfig(text: "mode = 'ask'").summary.contains("notes")))
    }

    @Test func agentNotesChecks() {
        let head = "mode = 'ask'\n[agent]\n"
        let atLimit = String(repeating: "a", count: BlackiceConfig.maximumNotesBytes)
        #expect((try? BlackiceConfig(text: head + "notes = '''" + atLimit + "'''"))?.agentNotes == atLimit)
        expectError(head + "notes = '''" + atLimit + "é'''", line: 3, containing: "notes is longer than 4 KiB")
        expectError(head + "notes = \"\"\"a\\u001bb\"\"\"", line: 3, containing: "without the control character U+001B")
        expectError(head + "notes = \"\"\"a\\rb\"\"\"", line: 3, containing: "without the control character U+000D")
        expectError(head + "notes = 'a\u{202E}b'", line: 3, containing: "without the control character U+202E")
        expectError(head + "notes = \"\"\"a\u{2066}b\"\"\"", line: 3, containing: "U+2066")
        expectError(head + "notes = \"\"\"a\u{7}b\"\"\"", line: 3, containing: "control character in string")
        expectError(head + "notes = \"\"\"a\rb\"\"\"", line: 3, containing: "carriage return")
        expectError(head + "notes = \"\"\"\nfirst \\\nsecond\"\"\"", line: 4, containing: "backslash at the end of a line")
        expectError(head + "notes = \"\"\"a\\qb\"\"\"", line: 3, containing: "invalid escape")
        expectError(head + "notes = \"\"\"\nnever closed\n", line: 3, containing: "unterminated multi-line string")
        expectError(head + "notes = '''a''''''", line: 3, containing: "more than five quotes")
        expectError(head + "notes = '''a''' trailing", line: 3, containing: "unexpected text after the value")
        expectError(head + "notes = ['a']", line: 3, containing: "notes must be a string")
        expectError(head + "notes = 'a'\nnotes = 'b'", line: 4, containing: "notes")
        expectError(head + "model = 'x'", line: 3, containing: "unknown key")
        expectError(head + "notes = 'a'\n[agent]\nnotes = 'b'", line: 4, containing: "[agent] appears twice (first on line 2)")
        expectError("mode = 'ask'\nnotes = \"\"\"a\"\"\"", line: 2, containing: "unknown key")
        expectError("mode = 'ask'\n[[hook]]\non = 'connection'\nrun = \"\"\"x\"\"\"", line: 4, containing: "only notes in [agent]")
    }

    @Test func errorsDoNotEchoControlCharacters() {
        guard let failure = error("mode = \"\\u001b[2Jask\"") else {
            Issue.record("expected an error")
            return
        }
        #expect(!failure.message.unicodeScalars.contains { $0.value < 0x20 })
        #expect(failure.message.contains("\\u{1b}"))
    }

    @Test func hostileInputsNeverCrash() {
        // Deterministic noise built from the grammar's own pieces: every result must be a value or a ConfigError.
        let pieces = ["mode", " = ", "'ask'", "\"", "'", "[[", "]]", "[", "]", ",", "#", "\n", "\r\n", "\\", "\\u", "{",
                      "hosts", "app", "allow", "hook", "=", "0", "9", ".", "*", "\u{0}", "é", "\t",
                      "[agent]", "notes = ", "\"\"\"", "'''", "\u{202E}"]
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<2000 {
            var text = ""
            for _ in 0..<Int(state % 24) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                text += pieces[Int((state >> 33) % UInt64(pieces.count))]
            }
            do { _ = try BlackiceConfig(text: text) } catch is ConfigError {} catch {
                Issue.record("non-ConfigError for \(text.debugDescription): \(error)")
            }
        }
    }
}

struct RuleMatchingTests {
    let config: BlackiceConfig

    init() throws {
        config = try BlackiceConfig(text: """
        mode = "block-all"
        [[allow]]
        app = "com.example.agent"
        team = "ABCDE12345"
        hosts = ["api.example.com", "*.models.example"]
        [[allow]]
        app = "com.apple.curl"
        hosts = ["example.com"]
        """)
    }

    @Test func matchesAppTeamAndHost() throws {
        let agent = SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345")
        #expect(config.allowRule(for: agent, host: "api.example.com")?.line == 2)
        #expect(config.allowRule(for: agent, host: "API.Example.COM.")?.line == 2)
        #expect(config.allowRule(for: agent, host: "eu.models.example") != nil)
        #expect(config.allowRule(for: agent, host: "models.example") == nil)
        #expect(config.allowRule(for: agent, host: "example.com") == nil)
    }

    @Test func anotherTeamWithTheSameSigningIDDoesNotMatch() {
        let impostor = SigningIdentity(signingID: "com.example.agent", teamID: "ZZZZZ99999")
        #expect(config.allowRule(for: impostor, host: "api.example.com") == nil)
        let unsigned = SigningIdentity(signingID: "com.example.agent", teamID: nil)
        #expect(config.allowRule(for: unsigned, host: "api.example.com") == nil)
    }

    @Test func ruleWithoutTeamMatchesOnlyApplePlatformCode() {
        #expect(config.allowRule(for: SigningIdentity(signingID: "com.apple.curl", teamID: nil), host: "example.com")?.line == 6)
        #expect(config.allowRule(for: SigningIdentity(signingID: "com.apple.curl", teamID: "ABCDE12345"), host: "example.com") == nil)
    }

    @Test func invalidHostNeverMatches() {
        let agent = SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345")
        for host in ["", "api.example.com\0", "203.0.113.7", "api example.com"] {
            #expect(config.allowRule(for: agent, host: host) == nil)
        }
    }
}

/// `answers` in [agent]: which agent's hook runs, or none, with people answering.
struct AgentAnswersTests {
    static let fxHook = "[[hook]]\non = 'connection'\nprogram = '/opt/fx'\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\ninstructions = 'fx'\n"
    static let codexHook = "[[hook]]\non = 'connection'\nprogram = '/opt/codex'\napp = 'codex'\nteam = '2DC432GLL2'\ninstructions = 'codex'\n"
    static let plainHook = "[[hook]]\non = 'connection'\nrun = 'logger blackice'\n"

    @Test func answersPicksTheAgentHookThatRuns() throws {
        let all = "mode = 'ask'\n" + Self.plainHook + Self.fxHook + Self.codexHook
        let every = try BlackiceConfig(text: all)
        #expect(every.answers == nil && every.activeHooks.count == 3)
        #expect(every.answering == Answering(agents: [.fx, .codex], answerer: nil))
        let codex = try BlackiceConfig(text: all + "[agent]\nanswers = 'codex'\n")
        #expect(codex.activeHooks.map { $0.program?.instructions } == [nil, .codex])
        #expect(codex.answering == Answering(agents: [.fx, .codex], answerer: .agent(.codex)))
        #expect(codex.summary.hasSuffix(", Codex answers") && codex.overview.contains("2 hooks"))
        let you = try BlackiceConfig(text: all + "[agent]\nanswers = \"you\"\n")
        #expect(you.activeHooks.map { $0.program?.instructions } == [nil] && you.answering.answerer == .you)
        // The daemon runs those.
        let daemon = try DaemonConfiguration(generation: 1, configText: all + "[agent]\nanswers = 'codex'\n")
        #expect(daemon.hooks.map { $0.program?.instructions } == [nil, .codex] && daemon.summary.contains("2 hooks"))
        // With no answers: the one agent with a hook, or you when none has one.
        #expect(try BlackiceConfig(text: "mode = 'ask'\n" + Self.fxHook).answering.answerer == .agent(.fx))
        #expect(try BlackiceConfig(text: "mode = 'ask'\n" + Self.plainHook).answering == Answering(agents: [], answerer: .you))
        #expect(Answerer.names == "\"fx\", \"claude-code\", \"codex\" or \"you\"")
        #expect(Answerer.all.map(\.title) == ["fx", "Claude Code", "Codex", "you"])
        #expect(Answerer.all.map(\.name).compactMap(Answerer.init(name:)) == Answerer.all && Answerer(name: "You") == nil)
    }

    @Test func answersChecks() {
        let head = "mode = 'ask'\n" + Self.fxHook + "[agent]\n"
        expectError(head + "answers = 'gemini'", line: 9,
                    containing: "answers must be \"fx\", \"claude-code\", \"codex\" or \"you\", not \"gemini\"")
        expectError(head + "answers = 'codex'", line: 9,
                    containing: "answers names \"codex\", but no [[hook]] has instructions = \"codex\": blackice agent connect codex")
        expectError(head + "answers = ['fx']", line: 9, containing: "answers must be a string")
        expectError(head + "answers = 'fx'\nanswers = 'you'", line: 10, containing: "answers")
    }

    @Test func settingAnswersEditsOnlyThatLine() throws {
        let base = "mode = 'ask'\n" + Self.fxHook + Self.codexHook
        // No [agent]: the table goes at the end.
        #expect(try BlackiceConfig.settingAnswers(.agent(.codex), in: base) == base + "\n[agent]\nanswers = \"codex\"\n")
        // Set already: that line is replaced, and the notes stay, a line in them that reads like the key included.
        let notes = base + "# mine\n[agent]\nnotes = \"\"\"\nanswers = 'not a key'\n\"\"\"\nanswers = 'fx' # who answers\n"
        #expect(try BlackiceConfig.settingAnswers(.you, in: notes)
            == base + "# mine\n[agent]\nnotes = \"\"\"\nanswers = 'not a key'\n\"\"\"\nanswers = \"you\"\n")
        // [agent] without it: under the header.
        #expect(try BlackiceConfig.settingAnswers(.agent(.fx), in: base + "[agent]\nnotes = 'n'\n")
            == base + "[agent]\nanswers = \"fx\"\nnotes = 'n'\n")
        // CRLF stays CRLF.
        #expect(try BlackiceConfig.settingAnswers(.you, in: "mode = 'ask'\r\n[agent]\r\nnotes = 'n'\r\n")
            == "mode = 'ask'\r\n[agent]\r\nanswers = \"you\"\r\nnotes = 'n'\r\n")
        #expect(try BlackiceConfig.settingAnswers(.you, in: "mode = 'ask'\r\n") == "mode = 'ask'\r\n\r\n[agent]\r\nanswers = \"you\"\r\n")
        // An agent with no hook cannot answer.
        #expect(throws: ConfigError.self) { try BlackiceConfig.settingAnswers(.agent(.claudeCode), in: base) }
    }

    /// `blackice mode ask --agent NAME` keeps the file's text but for `answers`, one generation on.
    @Test func providerConfigurationWithAnAnswerer() throws {
        let text = "mode = 'accept-all'\n" + Self.fxHook + Self.codexHook + "[agent]\nanswers = 'fx'\n"
        let saved = try ProviderConfiguration(generation: 3, mode: .acceptAll, configText: text)
        let codex = try saved.with(mode: .ask, answerer: .agent(.codex))
        #expect(codex.generation == 4 && codex.mode == .ask && codex.config.answers == .agent(.codex))
        #expect(codex.configText == text.replacingOccurrences(
            of: "answers = 'fx'", with: "answers = \"codex\"  # set by blackice mode; blackice.toml has \"fx\""))
        // Who answers already: only the mode changes, and the text stays.
        let same = try saved.with(mode: .ask, answerer: .agent(.fx))
        #expect(same.configText == text && same.generation == 4)
        #expect(throws: ConfigError.self) { try saved.with(mode: .ask, answerer: .agent(.claudeCode)) }
    }

    /// A switch writes what the file has in a comment on the `answers` line, and keeps it there
    /// through later switches; the file's own `settingAnswers` writes none.
    @Test func switchingAnswersKeepsWhatTheFileHas() throws {
        let base = "mode = 'ask'\n" + Self.fxHook + Self.codexHook
        let file = base + "[agent]\nanswers = 'fx' # mine\n"
        let codex = try BlackiceConfig.switchingAnswers(.agent(.codex), in: file)
        #expect(codex == base + "[agent]\nanswers = \"codex\"  # set by blackice mode; blackice.toml has \"fx\"\n")
        #expect(try BlackiceConfig(text: codex).answers == .agent(.codex))
        #expect(try BlackiceConfig.switchedAnswers(in: codex) == BlackiceConfig.SwitchedAnswers(fileHas: .agent(.fx)))
        // A second switch keeps the file's value, not the first switch's.
        let you = try BlackiceConfig.switchingAnswers(.you, in: codex)
        #expect(you == base + "[agent]\nanswers = \"you\"  # set by blackice mode; blackice.toml has \"fx\"\n")
        // A file that names no one, with CRLF line ends.
        let crlfFile = "mode = 'ask'\r\n" + Self.fxHook.replacingOccurrences(of: "\n", with: "\r\n")
        let crlf = try BlackiceConfig.switchingAnswers(.agent(.fx), in: crlfFile)
        #expect(crlf.hasSuffix("[agent]\r\nanswers = \"fx\"  # set by blackice mode; blackice.toml has none\r\n"))
        #expect(try BlackiceConfig.switchedAnswers(in: crlf) == BlackiceConfig.SwitchedAnswers(fileHas: nil))
        // The file's own text has none, and neither has a line that only looks like one.
        #expect(try BlackiceConfig.switchedAnswers(in: file) == nil)
        #expect(try BlackiceConfig.settingAnswers(.agent(.codex), in: file) == base + "[agent]\nanswers = \"codex\"\n")
        for comment in ["has \"gemini\"", "has \"\"", "has fx", "has \"fx\" too"] {
            let odd = base + "[agent]\nanswers = \"codex\"  # set by blackice mode; blackice.toml " + comment + "\n"
            #expect(try BlackiceConfig.switchedAnswers(in: odd) == nil)
        }
    }

    /// `blackice start` keeps a mode switched since the last start while the file's own mode is
    /// what it was then; a change in the file wins, and so does starting the file as written.
    @Test func startKeepsAModeSwitchUntilTheFileChanges() throws {
        let file = "mode = 'ask'\n" + Self.fxHook
        let first = try ProviderConfiguration.starting(configText: file, after: nil, keepingSwitches: true)
        #expect(first.mode == .ask && first.generation == 1)
        let switched = try first.with(mode: .acceptAll)
        let kept = try ProviderConfiguration.starting(configText: file, after: switched, keepingSwitches: true)
        #expect(kept.mode == .acceptAll && kept.configText == file && kept.generation == 3)
        // Kept again on the next start, since the file still says ask.
        #expect(try ProviderConfiguration.starting(configText: file, after: kept, keepingSwitches: true).mode == .acceptAll)
        let edited = file.replacingOccurrences(of: "mode = 'ask'", with: "mode = 'block-all'")
        #expect(try ProviderConfiguration.starting(configText: edited, after: switched, keepingSwitches: true).mode == .blockAll)
        #expect(try ProviderConfiguration.starting(configText: file, after: switched).mode == .ask)
        // Nothing switched: the file's mode.
        #expect(try ProviderConfiguration.starting(configText: edited, after: first, keepingSwitches: true).mode == .blockAll)
    }

    /// The same for who answers, read from the switch's comment, from a text 0.4.2 switched, and
    /// never for an agent whose hook the file no longer has.
    @Test func startKeepsAnAnswererSwitchUntilTheFileChanges() throws {
        let file = "mode = 'ask'\n" + Self.fxHook + Self.codexHook + "[agent]\nanswers = 'fx'\n"
        let first = try ProviderConfiguration.starting(configText: file, after: nil, keepingSwitches: true)
        let codex = try first.with(mode: .ask, answerer: .agent(.codex))
        let kept = try ProviderConfiguration.starting(configText: file, after: codex, keepingSwitches: true)
        #expect(kept.config.answers == .agent(.codex) && kept.mode == .ask)
        #expect(kept.configText == (try BlackiceConfig.switchingAnswers(.agent(.codex), in: file)))
        // The file's answers changed: the file wins.
        let you = file.replacingOccurrences(of: "answers = 'fx'", with: "answers = 'you'")
        #expect(try ProviderConfiguration.starting(configText: you, after: codex, keepingSwitches: true).configText == you)
        // Codex's hook is gone from the file: fx, as the file says.
        let noCodex = "mode = 'ask'\n" + Self.fxHook + "[agent]\nanswers = 'fx'\n"
        let fallback = try ProviderConfiguration.starting(configText: noCodex, after: codex, keepingSwitches: true)
        #expect(fallback.configText == noCodex && fallback.config.answers == .agent(.fx))
        // Switched again, back to what the file has: the next start loads the file's text.
        let back = try kept.with(mode: .ask, answerer: .agent(.fx))
        #expect(try BlackiceConfig.switchedAnswers(in: back.configText) == BlackiceConfig.SwitchedAnswers(fileHas: .agent(.fx)))
        #expect(try ProviderConfiguration.starting(configText: file, after: back, keepingSwitches: true).configText == file)
        // As written: the file's answers.
        #expect(try ProviderConfiguration.starting(configText: file, after: codex).configText == file)

        // 0.4.2 switched with no comment: the text in force is the file with only its answers line set.
        let legacy = try ProviderConfiguration(generation: 7, mode: .ask,
                                               configText: try BlackiceConfig.settingAnswers(.agent(.codex), in: file))
        #expect(legacy.answersSwitched(from: file) == BlackiceConfig.SwitchedAnswers(fileHas: .agent(.fx)))
        #expect(try ProviderConfiguration.starting(configText: file, after: legacy, keepingSwitches: true).config.answers
                == .agent(.codex))
        // ...unless the file changed elsewhere since: then it is the file's.
        let more = file + "[[allow]]\napp = 'com.vercel.fx'\nteam = 'JW6Y669B67'\nhosts = ['example.com']\n"
        #expect(legacy.answersSwitched(from: more) == nil)
        #expect(try ProviderConfiguration.starting(configText: more, after: legacy, keepingSwitches: true).configText == more)
        #expect(first.answersSwitched(from: file) == nil)
    }
}
