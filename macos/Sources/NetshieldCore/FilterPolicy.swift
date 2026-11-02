import Foundation

// The extension's decision for one flow, as a pure function. Sources/NetshieldFilter turns the
// verdict into NetworkExtension verdicts; everything that decides lives here and is unit-tested.
//
// Phase 1:
// - accept-all allows every flow (and the extension logs it);
// - block-all allows a flow only when an [[allow]] rule names its verified signing identity
//   and its host;
// - ask is phase 2: until then it decides like block-all and says so in the reason.
// In every mode, inbound flows pass (only outbound connections are filtered) and Apple's
// resolver may reach port 53, since rules name hosts and need name lookups to work.

public enum FlowDirection: Sendable {
    case outbound, inbound, unknown
}

public struct FlowFacts: Equatable, Sendable {
    public let direction: FlowDirection
    /// The code that opened the flow, checked by `CodeIdentity`.
    public let identity: IdentityResolution
    /// TCP or UDP over IPv4 or IPv6.
    public let internetSocket: Bool
    public let tcp: Bool
    /// The host name the system attached to the flow, if any. Not checked yet.
    public let hostname: String?
    public let port: UInt16?

    public init(direction: FlowDirection, identity: IdentityResolution, internetSocket: Bool, tcp: Bool,
                hostname: String?, port: UInt16?) {
        self.direction = direction
        self.identity = identity
        self.internetSocket = internetSocket
        self.tcp = tcp
        self.hostname = hostname
        self.port = port
    }
}

public enum FlowVerdict: Equatable, Sendable {
    case allow(reason: String)
    case drop(reason: String)
    /// Hold the flow, read its TLS ClientHello and decide again on the server name.
    case readServerName

    public var reason: String {
        switch self {
        case .allow(let reason), .drop(let reason): return reason
        case .readServerName: return "reading_server_name"
        }
    }
}

public enum FilterPolicy {
    /// Apple's resolver, the only code allowed to reach DNS in block-all without a rule.
    public static let systemResolver = SigningIdentity(signingID: "com.apple.mDNSResponder", teamID: nil)
    public static let dnsPort: UInt16 = 53
    /// The port where a missing host name is read from the TLS server name.
    public static let tlsPort: UInt16 = 443

    /// The verdict for a new flow. With no configuration installed, nothing passes.
    public static func decide(_ flow: FlowFacts, snapshot: ProviderConfiguration?) -> FlowVerdict {
        guard let snapshot else { return .drop(reason: "configuration_unavailable") }
        if flow.direction == .inbound { return .allow(reason: "inbound_not_filtered") }
        if flow.identity == .verified(systemResolver), flow.port == dnsPort {
            return .allow(reason: "system_resolver")
        }
        switch snapshot.mode {
        case .acceptAll: return .allow(reason: "accept_all")
        case .blockAll: return rules(flow, snapshot.config)
        case .ask: return askFallback(rules(flow, snapshot.config))
        }
    }

    /// The verdict once the ClientHello of a held flow has been read.
    public static func decide(_ flow: FlowFacts, serverName result: TLSHelloResult,
                              snapshot: ProviderConfiguration?) -> FlowVerdict {
        guard let snapshot else { return .drop(reason: "configuration_unavailable") }
        switch result {
        case .needMore:
            return .readServerName
        case .deny(let reason):
            return snapshot.mode == .ask ? askFallback(.drop(reason: reason)) : .drop(reason: reason)
        case .serverName(let name, _):
            if snapshot.mode == .acceptAll { return .allow(reason: "accept_all") }
            guard let identity = flow.identity.verifiedIdentity else { return .drop(reason: identityReason(flow.identity)) }
            let verdict: FlowVerdict
            if let host = normalizeHost(name) {
                verdict = snapshot.config.allowRule(for: identity, host: host)
                    .map { .allow(reason: "rule_line_\($0.line);server_name") } ?? .drop(reason: "no_rule")
            } else {
                verdict = .drop(reason: "server_name_invalid")
            }
            return snapshot.mode == .ask ? askFallback(verdict) : verdict
        }
    }

    private static func rules(_ flow: FlowFacts, _ config: NetshieldConfig) -> FlowVerdict {
        guard let identity = flow.identity.verifiedIdentity else { return .drop(reason: identityReason(flow.identity)) }
        guard flow.internetSocket else { return .drop(reason: "unsupported_socket") }
        if let raw = flow.hostname {
            guard let host = normalizeHost(raw) else { return .drop(reason: "hostname_invalid") }
            return config.allowRule(for: identity, host: host).map { .allow(reason: "rule_line_\($0.line)") }
                ?? .drop(reason: "no_rule")
        }
        // No host name from the system: worth reading the TLS server name only when a rule
        // could match this app at all.
        let hasRule = config.allow.contains { $0.app == identity.signingID && $0.team == identity.teamID }
        if hasRule && flow.tcp && flow.port == tlsPort { return .readServerName }
        return .drop(reason: hasRule ? "no_host" : "no_rule")
    }

    private static func identityReason(_ identity: IdentityResolution) -> String {
        switch identity {
        case .verified: return "verified"
        case .adHoc: return "adhoc_code"
        case .unresolved: return "unknown_identity"
        case .invalidSignature: return "invalid_signature"
        }
    }

    private static func askFallback(_ verdict: FlowVerdict) -> FlowVerdict {
        if case .drop(let reason) = verdict { return .drop(reason: reason + ";ask_is_phase_2") }
        return verdict
    }
}

/// One line of the extension's flow log, as JSON. The fields come from the flow, so they are
/// encoded, never pasted into the text.
public struct FlowLogLine: Encodable, Sendable {
    public let event = "flow"
    public let verdict: String
    public let reason: String
    public let app: String
    public let host: String?
    public let port: UInt16?
    public let mode: String
    public let generation: UInt64

    public init(flow: FlowFacts, verdict: FlowVerdict, snapshot: ProviderConfiguration?, serverName: String? = nil) {
        switch verdict {
        case .allow: self.verdict = "allow"
        case .drop: self.verdict = "drop"
        case .readServerName: self.verdict = "hold"
        }
        reason = verdict.reason
        app = flow.identity.label
        host = (serverName ?? flow.hostname).map { String($0.prefix(253)) }
        port = flow.port
        mode = snapshot?.mode.rawValue ?? "none"
        generation = snapshot?.generation ?? 0
    }

    enum CodingKeys: String, CodingKey { case event, verdict, reason, app, host, port, mode, generation }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return #"{"event":"flow","reason":"log_encoding_failed"}"#
        }
        return text
    }
}
