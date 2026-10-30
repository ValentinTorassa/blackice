import Foundation

enum AppFilterConstants {
    static let hostBundleID = "com.blackice.app"
    static let extensionBundleID = "com.blackice.app.filter"
    static let configurationKey = "blackice.apps.configuration"
    static let logSubsystem = "com.blackice.app.filter"
}

struct AppBindingDocument: Codable {
    let scope: String
    let teamID: String
    let signingID: String
    /// Exact UTF-8 policy bytes. No reserialization before computing the policy ID.
    let policyJSON: String
    enum CodingKeys: String, CodingKey {
        case scope, teamID = "team_id", signingID = "signing_id", policyJSON = "policy_json"
    }
    init(scope: String, teamID: String, signingID: String, policyJSON: String) {
        self.scope = scope; self.teamID = teamID; self.signingID = signingID; self.policyJSON = policyJSON
    }
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["scope", "team_id", "signing_id", "policy_json"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        teamID = try c.decode(String.self, forKey: .teamID)
        signingID = try c.decode(String.self, forKey: .signingID)
        policyJSON = try c.decode(String.self, forKey: .policyJSON)
    }
}

struct AppConfigurationDocument: Codable {
    let version: String
    let generation: UInt32
    let unmatched: String
    let hostnameMode: String
    let apps: [AppBindingDocument]
    enum CodingKeys: String, CodingKey { case version, generation, unmatched, hostnameMode = "hostname_mode", apps }
    init(generation: UInt32, unmatched: String, hostnameMode: String, apps: [AppBindingDocument]) {
        version = "blackice.apps/v0"
        self.generation = generation; self.unmatched = unmatched; self.hostnameMode = hostnameMode; self.apps = apps
    }
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(["version", "generation", "unmatched", "hostname_mode", "apps"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        generation = try c.decode(UInt32.self, forKey: .generation)
        unmatched = try c.decode(String.self, forKey: .unmatched)
        hostnameMode = try c.decode(String.self, forKey: .hostnameMode)
        apps = try c.decode([AppBindingDocument].self, forKey: .apps)
    }
}

func validSigningID(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= 255 && text.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
    }
}

func validTeamID(_ text: String) -> Bool {
    text.utf8.count == 10 && text.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
}

struct SigningIdentity: Equatable {
    let signingID: String
    let teamID: String?
    var label: String { (teamID ?? "apple") + "/" + signingID }
}

struct AppBinding {
    let scope: String
    let identity: SigningIdentity
    let policy: NetworkPolicy
}

struct AppConfiguration {
    let id: String
    let generation: UInt32
    let unmatched: String
    let hostnameMode: String
    let apps: [AppBinding]

    init(data: Data) throws {
        let raw = try StrictJSON.decode(AppConfigurationDocument.self, from: data)
        guard raw.version == "blackice.apps/v0", raw.generation > 0,
              ["allow", "deny"].contains(raw.unmatched),
              ["ip-only", "os-metadata"].contains(raw.hostnameMode),
              !raw.apps.isEmpty, raw.apps.count <= 256 else {
            throw ConfigurationError.invalid("invalid_app_configuration")
        }
        var scopes = Set<String>(), identities = Set<String>()
        apps = try raw.apps.map { app in
            guard validTeamID(app.teamID), validSigningID(app.signingID),
                  app.scope.hasPrefix("app-"), app.scope.utf8.count <= 64, validSigningID(app.scope),
                  scopes.insert(app.scope).inserted,
                  identities.insert(app.teamID + "/" + app.signingID).inserted else {
                throw ConfigurationError.invalid("invalid_or_duplicate_app_binding")
            }
            let policy = try NetworkPolicy(data: Data(app.policyJSON.utf8))
            guard raw.hostnameMode == "os-metadata" || policy.patterns.isEmpty else {
                throw ConfigurationError.invalid("unsupported_capability_hostname")
            }
            return AppBinding(scope: app.scope,
                              identity: SigningIdentity(signingID: app.signingID, teamID: app.teamID), policy: policy)
        }
        id = digestID(data); generation = raw.generation; unmatched = raw.unmatched; hostnameMode = raw.hostnameMode
    }
}

/// Immutable snapshots; no file reads or mutable policy references in a callback.
final class SnapshotStore {
    private let lock = NSLock()
    private var current: AppConfiguration?

    func read() -> AppConfiguration? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func install(_ candidate: AppConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        if let current {
            if candidate.generation == current.generation && candidate.id == current.id { return }
            guard candidate.generation > current.generation else {
                throw ConfigurationError.invalid("stale_generation")
            }
        }
        current = candidate
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }
}

struct FlowFacts {
    enum Direction { case inbound, outbound, unknown }
    let direction: Direction
    let app: SigningIdentity?
    let process: SigningIdentity?
    let supportedSocket: Bool
    let hostname: String?
    let ip: IPAddress?
    let port: UInt16?
}

struct AppDecision {
    let scope: String
    let policy: String
    let generation: UInt32
    let decision: Decision
}

enum AppEvaluator {
    static func evaluate(_ flow: FlowFacts, configuration: AppConfiguration?) -> AppDecision {
        guard let config = configuration else {
            return AppDecision(scope: "app-unavailable", policy: "unavailable", generation: 0,
                               decision: Decision(allowed: false, reason: "configuration_unavailable"))
        }
        func unbound(_ decision: Decision) -> AppDecision {
            AppDecision(scope: "app-unbound", policy: config.id, generation: config.generation, decision: decision)
        }
        // This is an outbound app filter, not an inbound host firewall.
        if flow.direction == .inbound { return unbound(Decision(allowed: true, reason: "outside_scope_inbound")) }
        guard flow.direction == .outbound else {
            return unbound(Decision(allowed: false, reason: "unknown_direction"))
        }
        // Unknown/invalid/unsigned source apps NEVER inherit the unmatched allow.
        guard let app = flow.app else { return unbound(Decision(allowed: false, reason: "unknown_app_identity")) }
        guard let binding = config.apps.first(where: { $0.identity == app }) else {
            return unbound(Decision(allowed: config.unmatched == "allow", reason: "outside_scope"))
        }
        let decision: Decision
        if !flow.supportedSocket {
            decision = Decision(allowed: false, reason: "unsupported_socket")
        } else {
            decision = binding.policy.evaluate(hostname: config.hostnameMode == "os-metadata" ? flow.hostname : nil,
                                               ip: flow.ip, port: flow.port)
        }
        return AppDecision(scope: binding.scope, policy: binding.policy.id, generation: config.generation, decision: decision)
    }
}
