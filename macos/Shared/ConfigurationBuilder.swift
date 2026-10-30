import Foundation

/// Read-only compiler for app bindings. Policies retain their exact UTF-8 bytes.
enum ConfigurationBuilder {
    static func make(arguments: [String], readPolicy: (String) throws -> Data) throws -> Data {
        let generation: UInt32
        let unmatched: String
        let hostnameMode: String
        let sources: [[String]] // policy path, Team ID, signing identifier, app scope
        if arguments.count == 6 && !arguments[0].hasPrefix("--") {
            // Preserve the original one-app command at generation 1.
            generation = 1
            unmatched = arguments[4]; hostnameMode = arguments[5]
            sources = [Array(arguments.prefix(4))]
        } else {
            guard arguments.count >= 11, (arguments.count - 6) % 5 == 0,
                  arguments[0] == "--generation", arguments[2] == "--unmatched",
                  arguments[4] == "--hostname-mode",
                  let value = UInt32(arguments[1]), value > 0, String(value) == arguments[1] else {
                throw ConfigurationError.invalid("make_config_arguments")
            }
            generation = value
            unmatched = arguments[3]; hostnameMode = arguments[5]
            sources = try stride(from: 6, to: arguments.count, by: 5).map { index in
                guard arguments[index] == "--app" else {
                    throw ConfigurationError.invalid("make_config_arguments")
                }
                return Array(arguments[(index + 1)...(index + 4)])
            }
        }
        guard sources.count <= 256, ["allow", "deny"].contains(unmatched),
              ["ip-only", "os-metadata"].contains(hostnameMode) else {
            throw ConfigurationError.invalid("make_config_arguments")
        }
        var totalBytes = 0
        let apps = try sources.map { source -> AppBindingDocument in
            let bytes = try readPolicy(source[0])
            guard bytes.count <= StrictJSON.maximumBytes - totalBytes else {
                throw ConfigurationError.invalid("configuration_size")
            }
            totalBytes += bytes.count
            _ = try NetworkPolicy(data: bytes)
            guard let policy = String(data: bytes, encoding: .utf8) else {
                throw ConfigurationError.invalid("policy_requires_utf8")
            }
            return AppBindingDocument(scope: source[3], teamID: source[1], signingID: source[2], policyJSON: policy)
        }
        let document = AppConfigurationDocument(generation: generation, unmatched: unmatched,
                                               hostnameMode: hostnameMode, apps: apps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let encoded = try encoder.encode(document)
        // Same strict duplicate/identity/capability/size checks as enable.
        _ = try AppConfiguration(data: encoded)
        return encoded
    }
}
