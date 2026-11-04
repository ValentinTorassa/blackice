import Foundation

// The extension's decision for one flow, as a pure function. Sources/BlackiceFilter turns the
// verdict into NetworkExtension verdicts; everything that decides lives here and is unit-tested.
//
// - accept-all allows every flow (and the extension logs it);
// - block-all allows a flow only when an [[allow]] rule names its verified signing identity and
//   its host, and the flow's address is among the host's answers from the system resolver. The
//   built-in table of macOS services (AppleServices) counts like a rule unless blackice.toml
//   turns it off, and a rule with hosts = ["*"] allows everything its app does, with no host
//   or address check;
// - ask allows what block-all allows, plus what a current approval names (with the same address
//   check), and pauses the rest to ask. Ad hoc signed code has no signing identity, so in ask
//   mode it is named by its cdhash; rules never name it.
// A host or address that does not check out is "no rule or approval matches", never an error.
// In every mode, inbound flows pass (only outbound connections are filtered) and Apple's
// resolver may reach port 53, since rules name hosts and need name lookups to work.
// In ask and block-all the extension also reads the resolver's DNS responses, passing every
// byte, to learn which names each address was given for (DNSMessage.swift). A flow with no host
// name whose address was given for exactly one name is decided on that name.
// A TCP flow on the TLS port that a host rule, the Apple services table or an approval would
// allow passes only once its ClientHello has been read: the server name must be the flow's host
// (from the system or from a DNS answer), or a host covered by itself. A hello with Encrypted
// Client Hello establishes no host, and only a hosts = ["*"] rule or accept-all lets it through.

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
    /// The process that opened the socket, when it is not the app the flow is for. mDNSResponder
    /// looks names up on behalf of apps, and macOS reports those DNS flows under the app.
    public let process: IdentityResolution?
    /// The names, normalized, that the system resolver's recent answers gave `remoteAddress`
    /// for, as the extension saw them in its DNS responses (DNSNameTable). Each came with the
    /// address, so it passes the host and address check for this flow.
    public let dnsNames: Set<String>

    public init(direction: FlowDirection, identity: IdentityResolution, internetSocket: Bool, tcp: Bool,
                hostname: String?, port: UInt16?, remoteAddress: IPAddress?, process: IdentityResolution? = nil,
                dnsNames: Set<String> = []) {
        self.direction = direction
        self.identity = identity
        self.process = process
        self.internetSocket = internetSocket
        self.tcp = tcp
        self.hostname = hostname
        self.port = port
        self.remoteAddress = remoteAddress
        self.dnsNames = dnsNames
    }

    /// The one name the remote address was given for, when there is exactly one. Several
    /// names (a shared CDN address) name nothing.
    public var dnsName: String? {
        guard remoteAddress != nil, dnsNames.count == 1 else { return nil }
        return dnsNames.first
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
    /// The system resolver's DNS flow in ask and block-all: allow it, and read its responses to
    /// learn which names its addresses were given for. Every byte passes unchanged.
    case learnNames

    public var reason: String {
        switch self {
        case .allow(let reason), .drop(let reason), .ask(let reason, _): return reason
        case .readServerName: return "reading_server_name"
        case .resolveHost: return "resolving_host"
        case .learnNames: return "system_resolver"
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
    /// Ask mode's limit for a paused flow the server already sees as connected, or a UDP flow.
    /// Servers close a TCP connection that sends no TLS hello (GitHub after 11 s, Cloudflare
    /// after 15 s, measured on 3 November 2026), and macOS drops a UDP flow paused for 10 s. The
    /// flow is dropped with `hold_expired` and its event stays open until the deadline, so an
    /// approval covers the app's next try.
    public static let connectedHoldSeconds: TimeInterval = 8

    /// The verdict for a new flow. With no configuration installed, nothing passes.
    public static func decide(_ flow: FlowFacts, snapshot: ProviderConfiguration?, context: PolicyContext) -> FlowVerdict {
        guard let snapshot else { return .drop(reason: "configuration_unavailable") }
        if flow.direction == .inbound { return .allow(reason: "inbound_not_filtered") }
        if flow.port == dnsPort,
           flow.identity == .verified(systemResolver) || flow.process == .verified(systemResolver) {
            return snapshot.mode == .acceptAll ? .allow(reason: "system_resolver") : .learnNames
        }
        if snapshot.mode == .acceptAll { return .allow(reason: "accept_all") }
        guard let identity = nameable(flow.identity, snapshot.mode) else { return .drop(reason: identityReason(flow.identity)) }
        guard flow.internetSocket else { return .drop(reason: "unsupported_socket") }
        if let verdict = anyHost(flow, snapshot) { return verdict }
        let tls = flow.tcp && flow.port == tlsPort
        if let raw = flow.hostname {
            guard let host = normalizeHost(raw) else { return .drop(reason: "hostname_invalid") }
            let verdict = named(identity, host: host, flow, snapshot, context, suffix: "")
            // The app chose this host name. On the TLS port the server name it sends picks the
            // site behind the address, so it is read before the flow passes, as for a DNS name.
            if tls, case .allow = verdict { return .readServerName }
            return verdict
        }
        // No host name from the system. Ask mode reads the TLS server name to have a host to ask
        // about; block-all reads it only when a rule or the Apple services table could match this app.
        // The system resolver gave the address for exactly one name: decide on that name now.
        if let name = flow.dnsName, let verdict = dnsNamed(identity, name: name, tls: tls, snapshot, context) {
            return verdict
        }
        if snapshot.mode == .ask { return tls ? .readServerName : .drop(reason: "no_host") }
        let hasRule = flow.identity.verifiedIdentity.map { hasRuleOrService($0, snapshot.config) } ?? false
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
        case .serverName(let name, let encrypted):
            if snapshot.mode == .acceptAll { return .allow(reason: "accept_all") }
            guard let identity = nameable(flow.identity, snapshot.mode) else { return .drop(reason: identityReason(flow.identity)) }
            if let verdict = anyHost(flow, snapshot) { return verdict }
            // Encrypted Client Hello: the server name in the clear names a public front end, and
            // the site the connection reaches is in the encrypted inner hello. A rule or an
            // approval for the front end, or for any host on the same provider's address, would
            // let the app reach every site behind it, so such a hello establishes no host. It is
            // dropped in block-all, and in ask mode too: an event could only name the front end.
            // The cost: a decoy ECH extension (GREASE), which Chrome sends when it has no ECH key
            // for the server, looks the same, so such apps need hosts = ["*"] to reach HTTPS.
            if encrypted { return .drop(reason: "encrypted_client_hello") }
            guard let host = normalizeHost(name) else { return .drop(reason: "server_name_invalid") }
            // The flow's host before its hello: the host name from the system, or the one name
            // the resolver gave the address for.
            let claimed: String?
            if let raw = flow.hostname {
                guard let named = normalizeHost(raw) else { return .drop(reason: "hostname_invalid") }
                claimed = named
            } else {
                claimed = flow.dnsName
            }
            // The app named one host and names another server in its hello, perhaps on the same
            // CDN address: that server name passes only if a rule or an approval covers it (and
            // the address checks out), never by asking.
            if let claimed, host != claimed {
                guard covers(identity, host, snapshot, context) else { return .drop(reason: "server_name_mismatch") }
                let verdict = named(identity, host: host, flow, snapshot, context, suffix: ";server_name")
                switch verdict {
                case .allow, .resolveHost: return verdict
                default: return .drop(reason: "server_name_mismatch")
                }
            }
            return named(identity, host: host, flow, snapshot, context, suffix: ";server_name")
        }
    }

    /// A rule with hosts = ["*"] for the flow's verified identity allows it outright: no host name
    /// is needed and no address is checked. Checked before anything looks at the host, so a VPN
    /// client or DNS proxy that connects by address is allowed instead of dropped as `no_host`.
    private static func anyHost(_ flow: FlowFacts, _ snapshot: ProviderConfiguration) -> FlowVerdict? {
        guard let signing = flow.identity.verifiedIdentity,
              let rule = snapshot.config.anyHostRule(for: signing) else { return nil }
        return .allow(reason: "rule_line_\(rule.line)")
    }

    /// Whether a rule names this app (for any host), or the Apple services table covers it.
    private static func hasRuleOrService(_ signing: SigningIdentity, _ config: BlackiceConfig) -> Bool {
        config.allow.contains { $0.names(signing) } || (config.appleServices && AppleServices.covers(signing))
    }

    /// A flow with no host name from the system whose address the resolver gave for exactly one
    /// name. That name came with the address, so the address check is met. Rules and approvals
    /// for it count; on the TLS port the ClientHello is still read, and a server name other than
    /// this one must be covered by itself. Ask mode asks about the name before the app has sent
    /// anything. nil in block-all when nothing covers the name: the server name may still be read.
    private static func dnsNamed(_ identity: AppIdentity, name: String, tls: Bool,
                                 _ snapshot: ProviderConfiguration, _ context: PolicyContext) -> FlowVerdict? {
        var line: Int?
        var service = false
        if case .signed(let signing) = identity {
            line = snapshot.config.allowRule(for: signing, host: name)?.line
            service = line == nil && snapshot.config.appleServices && AppleServices.allows(signing, host: name)
        }
        let ask = snapshot.mode == .ask
        if line != nil || service || (ask && context.approved(identity, name)) {
            if tls { return .readServerName }
            let reason = line.map { "rule_line_\($0)" } ?? (service ? "apple_service" : "approval")
            return .allow(reason: reason + ";dns_name")
        }
        return ask ? .ask(reason: "no_rule", addressMatches: true) : nil
    }

    /// Whether a rule, the Apple services table, or in ask mode a current approval, names this app
    /// and host.
    private static func covers(_ identity: AppIdentity, _ host: String,
                               _ snapshot: ProviderConfiguration, _ context: PolicyContext) -> Bool {
        if case .signed(let signing) = identity {
            if snapshot.config.allowRule(for: signing, host: host) != nil { return true }
            if snapshot.config.appleServices && AppleServices.allows(signing, host: host) { return true }
        }
        return snapshot.mode == .ask && context.approved(identity, host)
    }

    /// A flow paused by ask mode is held until its event's deadline, except one the server
    /// already sees as connected, or a UDP flow, which gets `connectedHoldSeconds`. That is a
    /// flow paused after its TLS hello was read, and a TCP flow on the TLS port with no host
    /// name from the system. Such an app connected with BSD sockets, and in XNU's published
    /// source (tcp_usr_connect, soisconnected) connect() sends the SYN at once; a pending first
    /// verdict only keeps the app from seeing the connection, so the server's clock is running.
    /// nil: the whole timeout.
    public static func holdLimit(_ flow: FlowFacts, afterServerName: Bool) -> TimeInterval? {
        if afterServerName || !flow.tcp || (flow.hostname == nil && needsServerName(flow)) { return connectedHoldSeconds }
        return nil
    }

    /// Whether a flow decided with the configuration of `generation` may still start to wait, for
    /// a lookup or an event, or be let through by an answer. Installing a configuration drops
    /// every paused flow (`configuration_changed`), but a flow callback that read the snapshot
    /// before the change can reach the pending list after that drop, and an answer taken just
    /// before the change can be applied after it. Such a flow is dropped the same way.
    public static func isCurrent(_ generation: UInt64, installed: ProviderConfiguration?) -> Bool {
        installed.map { $0.generation == generation } ?? false
    }

    /// The releases of an answer or a deadline as they apply now: an allow for a flow decided
    /// with another configuration than the installed one becomes a drop (`configuration_changed`).
    public static func current<Flow>(_ releases: [Release<Flow>], installed: ProviderConfiguration?,
                                     generation: (Flow) -> UInt64) -> [Release<Flow>] {
        releases.map { release in
            guard release.allow, !isCurrent(generation(release.flow), installed: installed) else { return release }
            return Release(flow: release.flow, allow: false, reason: "configuration_changed", eventID: release.eventID)
        }
    }

    /// A TCP flow on the TLS port: a host rule, the Apple services table or an approval allows it
    /// only once its ClientHello has been read, also after an approval, with or without a host
    /// name from the system.
    public static func needsServerName(_ flow: FlowFacts) -> Bool {
        flow.tcp && flow.port == tlsPort
    }

    /// A flow with a host name: rules, then the Apple services table, then approvals, each only once
    /// the address checks out.
    private static func named(_ identity: AppIdentity, host: String, _ flow: FlowFacts,
                              _ snapshot: ProviderConfiguration, _ context: PolicyContext, suffix: String) -> FlowVerdict {
        var line: Int?
        var service = false
        if case .signed(let signing) = identity {
            line = snapshot.config.allowRule(for: signing, host: host)?.line
            service = line == nil && snapshot.config.appleServices && AppleServices.allows(signing, host: host)
        }
        let ask = snapshot.mode == .ask
        let approved = ask && context.approved(identity, host)
        // Block-all with no rule or service by name: nothing to check.
        if !ask && line == nil && !service { return .drop(reason: "no_rule") }
        guard flow.remoteAddress != nil else { return .drop(reason: "no_address") }
        // An answer the resolver gave for this host and address counts like a lookup that found it.
        switch flow.dnsNames.contains(host) ? AddressCheck.match : context.address(host, flow.remoteAddress) {
        case .unknown:
            // Ask mode looks the host up even with no rule, so a paused flow knows whether an
            // approval may release it.
            return .resolveHost(host)
        case .match:
            if let line { return .allow(reason: "rule_line_\(line)" + suffix) }
            if service { return .allow(reason: "apple_service" + suffix) }
            if approved { return .allow(reason: "approval" + suffix) }
            return .ask(reason: "no_rule", addressMatches: true)
        case .mismatch:
            let named = line != nil || service || approved
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
        case .learnNames: self.verdict = "allow"
        }
        reason = verdict.reason
        app = flow.identity.label
        host = (serverName ?? flow.hostname ?? flow.dnsName).map { String($0.prefix(253)) }
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
