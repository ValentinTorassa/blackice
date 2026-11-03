import Foundation
import Testing
@testable import BlackiceCore

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func document(format: Any = ProviderConfiguration.format, generation: Any = 3, mode: Any = "block-all",
                      config: Any = policyRules) -> [String: Any] {
    ["format": format, "generation": generation, "mode": mode, "config": config]
}

private func refused(_ data: Data) -> String? {
    do {
        _ = try ProviderConfiguration(data: data)
        return nil
    } catch {
        return "\(error)"
    }
}

struct ProviderConfigurationTests {
    @Test func startsInTheFileModeAndRoundTrips() throws {
        let first = try ProviderConfiguration.starting(configText: policyRules, after: nil)
        #expect(first.generation == 1 && first.mode == .blockAll && first.configText == policyRules)
        #expect(first.config.allow.count == 2)
        #expect(first.summary == "mode block-all, 2 allow rules, 0 hooks, generation 1")
        #expect(try ProviderConfiguration(data: first.encoded()) == first)
        #expect(try ProviderConfiguration(vendorConfiguration: first.vendorConfiguration()) == first)

        let keys = try #require(JSONSerialization.jsonObject(with: first.encoded()) as? [String: Any]).keys
        #expect(Set(keys) == ["config", "format", "generation", "mode"])
        #expect(String(decoding: try first.encoded(), as: UTF8.self).hasPrefix(#"{"config":"#))
    }

    @Test func generationsOnlyGoUp() throws {
        let first = try ProviderConfiguration.starting(configText: policyRules, after: nil)
        let switched = try first.with(mode: .acceptAll)
        #expect(switched.generation == 2 && switched.mode == .acceptAll && switched.configText == policyRules)
        // start again: the file's own mode, one generation later.
        let restarted = try ProviderConfiguration.starting(configText: "mode = \"ask\"\n", after: switched)
        #expect(restarted.generation == 3 && restarted.mode == .ask && restarted.config.allow.isEmpty)

        let last = try ProviderConfiguration(generation: .max, mode: .ask, configText: policyRules)
        #expect(throws: ProviderConfigurationError("generation overflow")) { try last.with(mode: .blockAll) }
        #expect(throws: ProviderConfigurationError("generation must be at least 1")) {
            try ProviderConfiguration(generation: 0, mode: .ask, configText: policyRules)
        }
        #expect(throws: ConfigError.self) { try ProviderConfiguration.starting(configText: "mode = 'loud'\n", after: nil) }
    }

    @Test func decodingIsStrict() throws {
        #expect(refused(try json(document())) == nil)
        var extra = document()
        extra["rules"] = "allow everything"
        let cases: [(Data, String)] = [
            (try json(extra), "unexpected keys"),
            (try json(document().filter { $0.key != "mode" }), "expected shape"),
            (try json(document(format: "blackice.provider/v2")), "unknown provider configuration format"),
            (try json(document(mode: "allow-all")), "unknown mode"),
            (try json(document(generation: 0)), "at least 1"),
            (try json(document(generation: -1)), "expected shape"),
            (try json(document(generation: "3")), "expected shape"),
            (try json(document(config: 42)), "expected shape"),
            (Data("not json".utf8), "expected shape"),
            (Data("[]".utf8), "expected shape"),
            (Data(count: ProviderConfiguration.maximumBytes + 1), "too large"),
        ]
        for (data, fragment) in cases {
            let message = refused(data)
            #expect(message?.contains(fragment) == true, "\(fragment): \(message ?? "accepted")")
        }
        // The TOML inside is parsed with the same rules as blackice validate.
        #expect(throws: ConfigError.self) { try ProviderConfiguration(data: json(document(config: "mode = \"ask\"\nmode = \"ask\"\n"))) }
    }

    @Test func vendorConfigurationHoldsOneKey() throws {
        let data = try ProviderConfiguration.starting(configText: policyRules, after: nil).encoded()
        let bad: [[String: Any]?] = [
            nil, [:],
            [ProviderConfiguration.vendorKey: String(decoding: data, as: UTF8.self)],
            [ProviderConfiguration.vendorKey: data, "other": data],
            ["other": data],
        ]
        for values in bad {
            #expect(throws: ProviderConfigurationError("missing provider configuration")) {
                try ProviderConfiguration(vendorConfiguration: values)
            }
        }
    }
}

struct ProviderSnapshotStoreTests {
    @Test func newerGenerationsReplaceOlderNever() throws {
        let store = ProviderSnapshotStore()
        #expect(store.read() == nil)
        let first = try policySnapshot(.blockAll, generation: 5)
        #expect(try store.install(first))
        #expect(try store.install(first) == false)
        let next = try first.with(mode: .acceptAll)
        #expect(try store.install(next) && store.read() == next)

        #expect(throws: ProviderConfigurationError("stale generation 5, current 6")) { try store.install(first) }
        let sameGenerationOtherMode = try policySnapshot(.ask, generation: 6)
        #expect(throws: ProviderConfigurationError("stale generation 6, current 6")) {
            try store.install(sameGenerationOtherMode)
        }
        #expect(store.read() == next)

        // A new run of the extension starts from nothing and takes any generation.
        store.clear()
        #expect(store.read() == nil)
        #expect(try store.install(first) && store.read() == first)
    }
}
