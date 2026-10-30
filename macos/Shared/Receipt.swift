import Foundation

/// Flat src/core/receipt.zig schema. No payloads, URLs, tokens, paths or environment.
struct Receipt: Encodable {
    let ts: String
    let scope: String
    let policy: String
    let gen: UInt32
    let point: String
    var event: String
    var verdict: String? = nil
    var reason: String? = nil
    var rule: String? = nil
    var host: String? = nil
    var ip: String? = nil
    var port: UInt16? = nil
    var status: UInt8? = nil
    var dropped: UInt64? = nil
    var detail: String? = nil

    init(scope: String, policy: String, generation: UInt32, point: String, event: String, date: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ts = formatter.string(from: date)
        self.scope = scope; self.policy = policy; gen = generation; self.point = point; self.event = event
    }

    static func flow(_ flow: FlowFacts, result: AppDecision, hostnameMode: String?) -> Receipt {
        var receipt = Receipt(scope: result.scope, policy: result.policy, generation: result.generation,
                              point: "app_filter", event: "connect")
        receipt.verdict = result.decision.allowed ? "allow" : "deny"
        receipt.reason = result.decision.reason
        receipt.rule = result.decision.rule
        // Only normalized, bounded host metadata; never serialize arbitrary URL text.
        receipt.host = flow.hostname.flatMap(normalizeHost)
        receipt.ip = flow.ip?.text
        receipt.port = flow.port
        receipt.detail = "backend=network_extension;scope_kind=app;app=\(identityLabel(flow.app));" +
            "process=\(identityLabel(flow.process));hostname_source=\(flow.hostname == nil ? "absent" : "os_metadata");" +
            "hostname_mode=\(hostnameMode ?? "unavailable")"
        return receipt
    }

    private static func identityLabel(_ identity: SigningIdentity?) -> String {
        guard let label = identity?.label else { return "unknown" }
        // Keep both identities and name provenance within the core's 512-byte
        // detail cap. Long ASCII identifiers retain a hash of the complete label.
        return label.utf8.count <= 128 ? label : String(label.prefix(112)) + "...#" + digestID(Data(label.utf8))
    }

    /// Matches src/core/receipt.zig cleaning and byte caps. Swift Strings contain
    /// valid Unicode; control/bidi scalars become '?' without splitting UTF-8.
    static func clean(_ text: String, limit: Int) -> String {
        let capacity = text.utf8.count <= limit ? limit : limit - 3
        var result = "", count = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let control = value <= 0x1f || (0x7f...0x9f).contains(value) ||
                (0x200b...0x200f).contains(value) || (0x2028...0x202e).contains(value) ||
                (0x2060...0x2069).contains(value) || value == 0xfeff
            let character = control ? "?" : String(scalar)
            let length = character.utf8.count
            if count + length > capacity { return result + "..." }
            result += character
            count += length
        }
        return result
    }

    func jsonLine() throws -> String {
        var bounded = self
        bounded.event = Self.clean(event, limit: 32)
        bounded.reason = reason.map { Self.clean($0, limit: 64) }
        bounded.rule = rule.map { Self.clean($0, limit: 256) }
        bounded.host = host.map { Self.clean($0, limit: 256) }
        bounded.ip = ip.map { Self.clean($0, limit: 64) }
        bounded.detail = detail.map { Self.clean($0, limit: 512) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bounded)
        guard data.count < 4096, let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.invalid("receipt_size")
        }
        return text + "\n"
    }
}
