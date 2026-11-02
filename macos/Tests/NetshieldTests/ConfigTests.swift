import Foundation
import Testing
@testable import NetshieldCore

private let example = """
# netshield.toml
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 10    # no answer in time means deny

# Permanent rules. Checked before anything is asked.
[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]

[[hook]]
on = "connection"
run = 'fx ask "Use the netshield skill to decide whether to approve the pending connection"'
"""

/// The error a document produces, or nil if it parses.
private func error(_ text: String) -> ConfigError? {
    do {
        _ = try NetshieldConfig(text: text)
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
        let config = try NetshieldConfig(text: example)
        #expect(config.mode == .ask)
        #expect(config.timeoutSeconds == 10)
        #expect(config.allow.count == 1)
        #expect(config.allow[0].app == "com.example.agent")
        #expect(config.allow[0].team == "ABCDE12345")
        #expect(config.allow[0].hosts.map(\.source) == ["api.example.com"])
        #expect(config.allow[0].line == 6)
        #expect(config.hooks == [Hook(on: "connection",
                                      run: #"fx ask "Use the netshield skill to decide whether to approve the pending connection""#,
                                      line: 11)])
        #expect(config.summary == "mode ask, timeout 10 s, 1 allow rule, 1 hook")
    }

    @Test func exampleFileInTheRepositoryIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/netshield.toml")
        let config = try NetshieldConfig(data: Data(contentsOf: url))
        #expect(config.mode == .ask && config.allow.count == 1 && config.hooks.count == 1)
    }

    @Test func minimalDocumentUsesDefaults() throws {
        let config = try NetshieldConfig(text: "mode = \"block-all\"")
        #expect(config.mode == .blockAll)
        #expect(config.timeoutSeconds == NetshieldConfig.defaultTimeoutSeconds)
        #expect(config.allow.isEmpty && config.hooks.isEmpty)
        #expect(config.summary == "mode block-all, timeout 10 s, 0 allow rules, 0 hooks")
    }

    @Test(arguments: Mode.allCases)
    func everyModeParses(_ mode: Mode) throws {
        #expect(try NetshieldConfig(text: "mode = '\(mode.rawValue)'").mode == mode)
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
        let config = try NetshieldConfig(text: text)
        #expect(config.mode == .acceptAll)
        #expect(config.allow[0].team == nil)
        #expect(config.allow[0].hosts.map(\.source) == ["example.com", "*.example.org"])
    }

    @Test func basicStringEscapes() throws {
        let config = try NetshieldConfig(text: #"mode = "\u0061sk""# + "\n[[hook]]\non = \"connection\"\nrun = \"say \\\"hi\\\" \\\\ \\U0001F600\"")
        #expect(config.mode == .ask)
        #expect(config.hooks[0].run == "say \"hi\" \\ 😀")
    }

    @Test func literalStringsKeepBackslashes() throws {
        let config = try NetshieldConfig(text: "mode = 'ask'\n[[hook]]\non = 'connection'\nrun = 'C:\\path \\n'")
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
        let config = try NetshieldConfig(text: text)
        #expect(config.allow.map(\.app) == ["com.one", "com.two"])
        #expect(config.allow.map(\.line) == [2, 9])
        #expect(config.hooks.map(\.run) == ["first", "second"])
    }

    @Test func timeoutBounds() throws {
        #expect(try NetshieldConfig(text: "mode = 'ask'\ntimeout_seconds = 1").timeoutSeconds == 1)
        #expect(try NetshieldConfig(text: "mode = 'ask'\ntimeout_seconds = 120").timeoutSeconds == 120)
        expectError("mode = 'ask'\ntimeout_seconds = 0", line: 2, containing: "between 1 and 120")
        expectError("mode = 'ask'\ntimeout_seconds = 121", line: 2, containing: "between 1 and 120")
    }
}

struct ConfigRejectionTests {
    @Test func wholeFileProblems() {
        expectError("", line: nil, containing: "empty")
        expectError("# only a comment\n", line: nil, containing: "missing required key 'mode'")
        expectError("mode = 'ask'" + String(repeating: " ", count: NetshieldConfig.maximumBytes), line: nil, containing: "larger than 64 KiB")
        #expect(throws: ConfigError(line: nil, "the file is not valid UTF-8")) {
            try NetshieldConfig(data: Data([0x6D, 0x6F, 0x64, 0x65, 0x20, 0x3D, 0x20, 0x22, 0xC3, 0x28, 0x22]))
        }
        #expect(throws: ConfigError(line: 1, "byte order marks are not supported")) {
            try NetshieldConfig(data: Data([0xEF, 0xBB, 0xBF] + Array("mode = 'ask'".utf8)))
        }
    }

    @Test func fileAtTheSizeLimitIsRead() throws {
        let base = "mode = 'ask'\n"
        let padded = base + "#" + String(repeating: "x", count: NetshieldConfig.maximumBytes - base.utf8.count - 1)
        #expect(padded.utf8.count == NetshieldConfig.maximumBytes)
        #expect(try NetshieldConfig(text: padded).mode == .ask)
    }

    @Test func wrongModeAndTypes() {
        expectError("mode = \"allow-all\"", line: 1, containing: "mode must be")
        expectError("mode = \"ASK\"", line: 1, containing: "mode must be")
        expectError("mode = ask", line: 1, containing: "strings need quotes")
        expectError("mode = 1", line: 1, containing: "mode must be a string, not an integer")
        expectError("mode = true", line: 1, containing: "mode must be a string, not a boolean")
        expectError("mode = ['ask']", line: 1, containing: "mode must be a string, not an array")
        expectError("mode = 'ask'\ntimeout_seconds = \"10\"", line: 2, containing: "must be an integer, not a string")
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
    }

    @Test func unsupportedSyntax() {
        expectError("mode.x = 'ask'", line: 1, containing: "dotted keys are not supported")
        expectError("\"mode\" = 'ask'", line: 1, containing: "quoted keys are not supported")
        expectError("'mode' = 'ask'", line: 1, containing: "quoted keys are not supported")
        expectError("mode = 'ask'\n[allow]", line: 2, containing: "only [[allow]] and [[hook]] tables")
        expectError("mode = 'ask'\n[[allow.extra]]", line: 2, containing: "dotted table names")
        expectError("mode = 'ask'\n[[rules]]", line: 2, containing: "unknown table [[rules]]")
        expectError("mode = 'ask'\n[[allow]", line: 2, containing: "expected ']]'")
        expectError("mode = 'ask'\n[ [allow] ]", line: 2, containing: "only [[allow]] and [[hook]] tables")
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
        expectError(head + "app = 'com.a'\nhosts = ['1.2.3.4']", line: 4, containing: "not a host name")
        expectError(head + "app = 'com.a'\nhosts = ['*']", line: 4, containing: "not a host name")
        expectError(head + "app = 'com.a'\nhosts = ['a.example', 'A.Example.']", line: 4, containing: "appears twice")
        let tooMany = "[" + (0...NetshieldConfig.maximumHostsPerRule).map { "'h\($0).example'" }.joined(separator: ",") + "]"
        expectError(head + "app = 'com.a'\nhosts = " + tooMany, line: 4, containing: "more than 256 entries")
    }

    @Test func hookChecks() {
        let head = "mode = 'ask'\n[[hook]]\n"
        expectError(head + "run = 'x'", line: 2, containing: "needs an 'on' key")
        expectError(head + "on = 'connection'", line: 2, containing: "needs a 'run' key")
        expectError(head + "on = 'dns'\nrun = 'x'", line: 3, containing: "on must be \"connection\"")
        expectError(head + "on = 'connection'\nrun = '   '", line: 4, containing: "must not be empty")
        expectError(head + "on = 'connection'\nrun = \"line one\\nline two\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = \"esc \\u001b[31m\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = \"c1 \\u0085\"", line: 4, containing: "no control characters")
        expectError(head + "on = 'connection'\nrun = '" + String(repeating: "x", count: 4097) + "'", line: 4, containing: "longer than 4096 bytes")
    }

    @Test func tableCountLimits() {
        let rule = "[[allow]]\napp = 'com.a'\nhosts = ['a.example']\n"
        let rules = "mode = 'ask'\n" + String(repeating: rule, count: NetshieldConfig.maximumAllowRules + 1)
        expectError(rules, line: 2 + NetshieldConfig.maximumAllowRules * 3, containing: "more than 256 [[allow]] rules")
        let hook = "[[hook]]\non = 'connection'\nrun = 'x'\n"
        let hooks = "mode = 'ask'\n" + String(repeating: hook, count: NetshieldConfig.maximumHooks + 1)
        expectError(hooks, line: 2 + NetshieldConfig.maximumHooks * 3, containing: "more than 8 [[hook]] tables")
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
                      "hosts", "app", "allow", "hook", "=", "0", "9", ".", "*", "\u{0}", "é", "\t"]
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<2000 {
            var text = ""
            for _ in 0..<Int(state % 24) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                text += pieces[Int((state >> 33) % UInt64(pieces.count))]
            }
            do { _ = try NetshieldConfig(text: text) } catch is ConfigError {} catch {
                Issue.record("non-ConfigError for \(text.debugDescription): \(error)")
            }
        }
    }
}

struct RuleMatchingTests {
    let config: NetshieldConfig

    init() throws {
        config = try NetshieldConfig(text: """
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
