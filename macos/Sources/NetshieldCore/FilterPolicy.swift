import Foundation

// The extension's decision for one flow, as a pure function. Sources/NetshieldFilter turns the
// verdict into NetworkExtension verdicts; everything that decides lives here and is unit-tested.
//
// - accept-all allows every flow (and the extension logs it);
// - block-all allows a flow only when an [[allow]] rule names its verified signing identity and
//   its host, and the flow's address is among the host's answers from the system resolver;
// - ask allows what block-all allows, plus what a current approval names (with the same address
//   check), and pauses the rest to ask. Ad hoc signed code has no signing identity, so in ask
//   mode it is named by its cdhash; rules never name it.
// A host or address that does not check out is "no rule or approval matches", never an error.
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
    /// The host name the system attached to the flow, if any. Chosen by the app, so it counts
    /// only once the remote address checks out against it.
    public let hostname: String?
    public let port: UInt16?
    /// The address the flow connects to.
    public let remoteAddress: IPAddress?

    public init(direction: FlowDirection, identity: IdentityResolution, internetSocket: Bool, tcp: Bool,
                hostname: String?, port: UInt16?, remoteAddress: IPAddress?) {
        self.direction = direction
        self.identity = identity
        self.internetSocket = internetSocket
        self.tcp = tcp
        self.hostname = hostname
        self.port = port
        self.remoteAddress = remoteAddress
    }
}

public enum FlowVerdict: Equatable, Sendable {
    case allow(reason: String)
    case drop(reason: String)
    /// Hold the flow, read its TLS ClientHello and decide again on the server name.
    case readServerName
    /// Pause the flow, look the host up with the system resolver, then decide again.
    case resolveHost(String)
    /// Ask mode: pause the flow and raise an event, or join the one already pending for the same
    /// app, host and port. With `addressMatches` false an approval does not release this flow.
    case ask(reason: String, addressMatches: Bool)

    public var reason: String {
        switch self {
        case .allow(let reason), .drop(let reason), .ask(let reason, _): return reason
        case .readServerName: return "reading_server_name"
        case .resolveHost: return "resolving_host"
        }
    }
}

/// What the policy needs to know besides the flow and the configuration.
public struct PolicyContext {
    /// Whether a current approval names this app and host (normalized). Only ask mode asks.
    public let approved: (AppIdentity, String) -> Bool
    /// What is known about this host (normalized) and the flow's address.
    public let address: (String, IPAddress?) -> AddressCheck

    public init(approved: @escaping (AppIdentity, String) -> Bool,
                address: @escaping (String, IPAddress?) -> AddressCheck) {
        self.approved = approved
        self.address = address
    }
}

public enum FilterPolicy {
    /// Apple's resolver, the only code allowed to reach DNS in block-all without a rule.
    public static let systemResolver = SigningIdentity(signingID: "com.apple.mDNSResponder", teamID: nil)
    public static let dnsPort: UInt16 = 53
    /// The port where a missing host name is read from the TLS server name.
    public static let tlsPort: UInt16 = 443

    /// The verdict for a new flow. With no configuration installed, nothing passes.
    public static func decide(_ flow: FlowFacts, snapshot: ProviderConfiguration?, context: PolicyContext) -> FlowVerdict {
        guard let snapshot else { return .drop(reason: "configuration_unavailable") }
        if flow.direction == .inbound { return .allow(reason: "inbound_not_filtered") }
        if flow.identity == .verified(systemResolver), flow.port == dnsPort {
            return .allow(reason: "system_resolver")
        }
        if snapshot.mode == .acceptAll { return .allow(reason: "accept_all") }
        guard let identity = nameable(flow.identity, snapshot.mode) else { return .drop(reason: identityReason(flow.identity)) }
        guard flow.internetSocket else { return .drop(reason: "unsupported_socket") }
        if let raw = flow.hostname {
            guard let host = normalizeHost(raw) else { return .drop(reason: "hostname_invalid") }
            return named(identity, host: host, flow, snapshot, context, suffix: "")
        }
        // No host name from the system. Ask mode reads the TLS server name to have a host to ask
        // about; block-all reads it only when a rule could match this app at all.
        let tls = flow.tcp && flow.port == tlsPort
        if snapshot.mode == .ask { return tls ? .readServerName : .drop(reason: "no_host") }
        let hasRule = flow.identity.verifiedIdentity.map { signing in
            snapshot.config.allow.contains { $0.app == signing.signingID && $0.team == signing.teamID }
        } ?? false
        if hasRule && tls { return .readServerName }
        return .drop(reason: hasRule ? "no_host" : "no_rule")
    }

    /// The verdict once the ClientHello of a held flow has been read.
    public static func decide(_ flow: FlowFacts, serverName result: TLSHelloResult,
                              snapshot: ProviderConfiguration?, context: PolicyContext) -> FlowVerdict {
        guard let snapshot else { return .drop(reason: "configuration_unavailable") }
        switch result {
        case .needMore:
            return .readServerName
        case .deny(let reason):
            return .drop(reason: reason)
        case .serverName(let name, _):
            if snapshot.mode == .acceptAll { return .allow(reason: "accept_all") }
            guard let identity = nameable(flow.identity, snapshot.mode) else { return .drop(reason: identityReason(flow.identity)) }
            guard let host = normalizeHost(name) else { return .drop(reason: "server_name_invalid") }
            return named(identity, host: host, flow, snapshot, context, suffix: ";server_name")
        }
    }

    /// A flow with a host name: rules, then approvals, each only once the address checks out.
    private static func named(_ identity: AppIdentity, host: String, _ flow: FlowFacts,
                              _ snapshot: ProviderConfiguration, _ context: PolicyContext, suffix: String) -> FlowVerdict {
        var line: Int?
        if case .signed(let signing) = identity { line = snapshot.config.allowRule(for: signing, host: host)?.line }
        let ask = snapshot.mode == .ask
        let approved = ask && context.approved(identity, host)
        // Block-all with no rule by name: nothing to check.
        if !ask && line == nil { return .drop(reason: "no_rule") }
        guard flow.remoteAddress != nil else { return .drop(reason: "no_address") }
        switch context.address(host, flow.remoteAddress) {
        case .unknown:
            // Ask mode looks the host up even with no rule, so a paused flow knows whether an
            // approval may release it.
            return .resolveHost(host)
        case .match:
            if let line { return .allow(reason: "rule_line_\(line)" + suffix) }
            if approved { return .allow(reason: "approval" + suffix) }
            return .ask(reason: "no_rule", addressMatches: true)
        case .mismatch:
            let named = line != nil || approved
            if !ask { return .drop(reason: "address_mismatch") }
            return .ask(reason: named ? "address_mismatch" : "no_rule", addressMatches: false)
        }
    }

    /// Block-all needs a signing identity; ask mode also takes ad hoc code, by cdhash.
    private static func nameable(_ identity: IdentityResolution, _ mode: Mode) -> AppIdentity? {
        if mode == .ask { return identity.appIdentity }
        return identity.verifiedIdentity.map { .signed($0) }
    }

    private static func identityReason(_ identity: IdentityResolution) -> String {
        switch identity {
        case .verified: return "verified"
        case .adHoc: return "adhoc_code"
        case .unresolved: return "unknown_identity"
        case .invalidSignature: return "invalid_signature"
        }
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
        case .resolveHost: self.verdict = "resolve"
        case .ask: self.verdict = "ask"
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
