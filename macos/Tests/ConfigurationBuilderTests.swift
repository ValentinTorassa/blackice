import Foundation

func configurationBuilderRegressions() throws {
    let service = Data("{\"version\":\"blackice.policy/v0\", \"network\":{\"mode\":\"allowlist\",\"allow\":[\"example.com\"],\"ports\":[443]}}\r\n".utf8)
    let feeds = Data(#"{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["www.swift.org"],"ports":[443]}}"#.utf8)
    var files = ["service.json": service, "feeds.json": feeds]
    func read(_ path: String) throws -> Data {
        guard let bytes = files[path] else { throw ConfigurationError.invalid("missing_test_policy") }
        return bytes
    }
    let flags = ["--generation", "2", "--unmatched", "allow", "--hostname-mode", "os-metadata"]
    let probe = ["--app", "service.json", "ABCDE12345", "com.example.probe", "app-probe"]
    let news = ["--app", "feeds.json", "FGHIJ67890", "com.example.news", "app-news"]
    let initial = try ConfigurationBuilder.make(arguments: flags + probe + news, readPolicy: read)
    let decoded = try StrictJSON.decode(AppConfigurationDocument.self, from: initial)
    let config = try AppConfiguration(data: initial)
    expect(config.generation == 2 && config.apps.count == 2 && config.unmatched == "allow", "multi-app generation and safe mode")
    expect(decoded.apps.map { Data($0.policyJSON.utf8) } == [service, feeds], "multi-app preserves all policy bytes including CRLF")
    expect(decoded.apps.map { $0.policySHA256 } == [digestHex(service), digestHex(feeds)], "multi-app original-byte hashes")
    expect(config.apps.map { $0.policy.id } == [digestID(service), digestID(feeds)], "app and task scope policy IDs match")
    expect(config.apps.map { $0.identity.teamID } == ["ABCDE12345", "FGHIJ67890"], "separate exact identity pairs")

    let legacy = try ConfigurationBuilder.make(arguments: ["service.json", "ABCDE12345", "com.example.probe", "app-probe", "allow", "os-metadata"], readPolicy: read)
    expect(try AppConfiguration(data: legacy).generation == 1, "legacy one-app command retains generation 1")
    expect(try StrictJSON.decode(AppConfigurationDocument.self, from: legacy).apps[0].policySHA256 == digestHex(service), "legacy exact bytes retained")

    files["feeds.json"] = Data(#"{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["www.swift.org","netnewswire.blog"],"ports":[443]}}"#.utf8)
    var nextFlags = flags; nextFlags[1] = "3"
    let next = try AppConfiguration(data: ConfigurationBuilder.make(arguments: nextFlags + probe + news, readPolicy: read))
    try ConfigurationUpdate.validate(next, replacing: config)
    expect(next.apps[0].policy.id == config.apps[0].policy.id && next.apps[1].policy.id != config.apps[1].policy.id, "editing feed policy preserves probe identity/hash")
    expect(next.apps[1].policy.checkHost("netnewswire.blog").allowed, "new generation permits added feed host")

    for invalid in ["0", "-1", "+1", "01", "4294967296", "1.0", ""] {
        var arguments = flags; arguments[1] = invalid
        rejects("invalid builder generation") { _ = try ConfigurationBuilder.make(arguments: arguments + probe, readPolicy: read) }
    }
    for arguments in [[], flags, Array((flags + probe).dropLast()), flags + probe + ["extra"],
                      ["--typo"] + Array((flags + probe).dropFirst())] {
        rejects("incomplete or unknown builder flags") { _ = try ConfigurationBuilder.make(arguments: arguments, readPolicy: read) }
    }
    rejects("duplicate identity and scope") { _ = try ConfigurationBuilder.make(arguments: flags + probe + probe, readPolicy: read) }
    var duplicateScope = news; duplicateScope[4] = "app-probe"
    rejects("duplicate scope with separate identity") { _ = try ConfigurationBuilder.make(arguments: flags + probe + duplicateScope, readPolicy: read) }
    var duplicateIdentity = probe; duplicateIdentity[4] = "app-other"
    rejects("duplicate identity with separate scope") { _ = try ConfigurationBuilder.make(arguments: flags + probe + duplicateIdentity, readPolicy: read) }
    var invalidTeam = probe; invalidTeam[2] = "TEAM_ID"
    rejects("unsubstituted Team ID rejected") { _ = try ConfigurationBuilder.make(arguments: flags + invalidTeam, readPolicy: read) }
    var ipOnly = flags; ipOnly[5] = "ip-only"
    rejects("domain rules require OS metadata mode") { _ = try ConfigurationBuilder.make(arguments: ipOnly + probe, readPolicy: read) }
    var unknown = flags; unknown[3] = "typo"
    rejects("unknown unmatched mode") { _ = try ConfigurationBuilder.make(arguments: unknown + probe, readPolicy: read) }
    rejects("file read errors propagate") { _ = try ConfigurationBuilder.make(arguments: flags + probe, readPolicy: { _ in throw ConfigurationError.invalid("read_failed") }) }
    rejects("invalid UTF-8 policy") { _ = try ConfigurationBuilder.make(arguments: flags + probe, readPolicy: { _ in Data([0xff]) }) }
    rejects("oversized policy") { _ = try ConfigurationBuilder.make(arguments: flags + probe, readPolicy: { _ in Data(repeating: 32, count: StrictJSON.maximumBytes + 1) }) }
    var reads = 0
    let tooMany = Array(repeating: probe, count: 257).flatMap { $0 }
    rejects("app count cap before reads") {
        _ = try ConfigurationBuilder.make(arguments: flags + tooMany, readPolicy: { _ in reads += 1; return service })
    }
    expect(reads == 0, "too many bindings do not read policies")
}
