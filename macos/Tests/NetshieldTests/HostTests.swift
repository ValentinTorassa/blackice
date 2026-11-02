import Testing
@testable import NetshieldCore

// Vectors from blackice macos/Tests/main.swift at 45a7870, plus a few for the wildcard boundary.
struct HostTests {
    @Test func normalizesCaseAndTrailingDot() {
        #expect(normalizeHost("API.Example.COM.") == "api.example.com")
    }

    @Test(arguments: ["", "a..b", ".a", "bad host", "éxample.com", String(repeating: "a", count: 64) + ".com",
                      "a\0b.com", "exa:mple.com", String(repeating: "a.", count: 127) + "com"])
    func refusesInvalidNames(_ name: String) {
        #expect(normalizeHost(name) == nil)
    }

    @Test(arguments: ["2130706433", "127.1", "0x7f000001", "0X7F.1", "0177.0.0.1", "1.2.3.4.", "foo.0x", "1.2.3.4"])
    func refusesNumericNames(_ name: String) {
        #expect(normalizeHost(name) == nil)
    }

    @Test func exactAndWildcardBoundaries() throws {
        let exact = try #require(DomainPattern("Example.COM."))
        let wildcard = try #require(DomainPattern("*.npmjs.org"))
        #expect(exact.matches("example.com"))
        #expect(!exact.matches("www.example.com"))
        #expect(wildcard.matches("registry.npmjs.org") && wildcard.matches("a.b.npmjs.org"))
        for host in ["npmjs.org", "evilnpmjs.org", "registry.npmjs.org.attacker.test"] {
            #expect(!wildcard.matches(host), "wildcard must not match \(host)")
        }
    }

    @Test(arguments: ["*", "www.*.com", "1.2.3.4", "*.1.2.3.4", "a.*.com", "a\0b.com", "2130706433", "127.1",
                      "0x7f000001", "foo.0x", "**.example.com", "*example.com", "*.", "::1"])
    func refusesInvalidPatterns(_ pattern: String) {
        #expect(DomainPattern(pattern) == nil)
    }

    @Test func identityValidatorsRefuseRequirementInjection() {
        #expect(validSigningID("com.example.agent") && validTeamID("ABCDE12345"))
        #expect(!validTeamID("A\" OR true") && !validSigningID("com.a\" or true"))
        #expect(!validTeamID("abcde12345") && !validTeamID("ABCDE1234") && !validSigningID(""))
        #expect(!validSigningID(String(repeating: "a", count: 256)))
    }
}
