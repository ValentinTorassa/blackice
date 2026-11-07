import Foundation

// The messages that cross XPC between the extension, the daemon and the CLI (phase 2).
//
// The NSXPC protocols in Sources/BlackiceXPC carry each message as one JSON Data argument, so
// all parsing and checking happens here, in plain code with tests. Every receiver decodes with
// `Messages.decode`, which refuses oversized data, a different protocol version and any field
// outside the form the sender is supposed to produce. Nothing is trusted because of who sent
// it: the code signature check on the connection comes first, and these checks come after.

public struct MessageError: Error, Equatable, CustomStringConvertible, Sendable {
    public let field: String
    public let problem: String

    public init(_ field: String, _ problem: String) {
        self.field = field
        self.problem = problem
    }

    public var description: String { "\(field) \(problem)" }
}

public protocol CheckedMessage: Codable, Sendable {
    /// The most bytes the message takes once encoded. `Messages.encode` refuses to make a larger
    /// one and `Messages.decode` refuses to read one, so both ends hold to the same limit.
    static var maximumBytes: Int { get }
    var version: Int { get }
    func validate(now: Date) throws
}

extension CheckedMessage {
    public static var maximumBytes: Int { Messages.maximumBytes }
}

public enum Messages {
    /// Bumped on any change to a message; both ends must agree. 2: the register reply carries the
    /// configuration, and events carry its generation. 3: the pending reply names the
    /// configuration the extension decides with. 4: the pending reply lists the remembered denials.
    public static let version = 4
    /// The limit of a message that sets none of its own. The pending reply and the register reply
    /// set theirs from the largest content their checks accept.
    public static let maximumBytes = 262_144

    /// An upper bound on a JSON string of `bytes` UTF-8 bytes, quotes included. JSONEncoder writes
    /// `"`, `\`, `/`, tab, line feed and carriage return as two bytes and copies the rest. The
    /// other C0 controls, which take six, never get this far: the blackice.toml parser and
    /// `validPath` refuse them.
    public static func jsonStringBytes(_ bytes: Int) -> Int { 2 * bytes + 2 }

    public static func encode<Message: CheckedMessage>(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        guard data.count <= Message.maximumBytes else { throw MessageError("message", "is larger than \(Message.maximumBytes) bytes") }
        return data
    }

    public static func decode<Message: CheckedMessage>(_ type: Message.Type, from data: Data, now: Date = Date()) throws -> Message {
        guard !data.isEmpty, data.count <= Message.maximumBytes else { throw MessageError("message", "is empty or too large") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message: Message
        do {
            message = try decoder.decode(Message.self, from: data)
        } catch {
            throw MessageError("message", "is not valid JSON for \(Message.self)")
        }
        guard message.version == version else { throw MessageError("version", "must be \(version)") }
        try message.validate(now: now)
        return message
    }
}

/// An app as messages name it: `signing_id` (with `team_id` unless it is Apple platform code),
/// or `cdhash` for ad hoc code. Never both.
public struct AppReference: Codable, Equatable, Sendable {
    public let signingID: String?
    public let teamID: String?
    public let cdhash: String?

    public init(signingID: String?, teamID: String?, cdhash: String?) {
        self.signingID = signingID
        self.teamID = teamID
        self.cdhash = cdhash
    }

    public init(_ identity: AppIdentity) {
        switch identity {
        case .signed(let signing): self.init(signingID: signing.signingID, teamID: signing.teamID, cdhash: nil)
        case .cdhash(let hash): self.init(signingID: nil, teamID: nil, cdhash: hash)
        }
    }

    /// nil unless exactly one form is present and valid.
    public var identity: AppIdentity? {
        switch (signingID, cdhash) {
        case (let id?, nil):
            guard validSigningID(id), teamID.map(validTeamID) ?? true else { return nil }
            return .signed(SigningIdentity(signingID: id, teamID: teamID))
        case (nil, let hash?):
            guard teamID == nil, validCDHash(hash) else { return nil }
            return .cdhash(hash)
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case signingID = "signing_id"
        case teamID = "team_id"
        case cdhash
    }
}

// MARK: - Daemon <-> extension

/// The daemon asks to receive events on this connection, and for the configuration to run hooks
/// with. It asks again, on the same connection, when an event names a generation it does not hold.
public struct RegisterRequest: CheckedMessage, Equatable {
    public let version: Int
    public init() { version = Messages.version }
    public func validate(now: Date) throws {}
}

/// The extension's answer to a registration. When accepted, it carries the configuration the
/// extension holds now, the one `blackice start` and `blackice mode` saved after Touch ID: the
/// blackice.toml text and its generation. The daemon takes its hooks and timeout from it and from
/// nowhere else; the text is parsed with the same strict BlackiceConfig parser as the file.
public struct RegisterReply: CheckedMessage, Equatable {
    /// The largest blackice.toml once escaped, as in the provider configuration, and its JSON.
    public static let maximumBytes = ProviderConfiguration.maximumBytes

    public let version: Int
    public let accepted: Bool
    public let generation: UInt64?
    public let config: String?

    /// Accepted, with this configuration.
    public init(generation: UInt64, configText: String) {
        self.init(version: Messages.version, accepted: true, generation: generation, config: configText)
    }

    public static let refused = RegisterReply(version: Messages.version, accepted: false, generation: nil, config: nil)

    private init(version: Int, accepted: Bool, generation: UInt64?, config: String?) {
        self.version = version
        self.accepted = accepted
        self.generation = generation
        self.config = config
    }

    public func validate(now: Date) throws {
        guard accepted else {
            guard generation == nil, config == nil else { throw MessageError("configuration", "must be absent when refused") }
            return
        }
        guard let generation, generation > 0 else { throw MessageError("generation", "must be at least 1") }
        guard let config, config.utf8.count <= BlackiceConfig.maximumBytes else {
            throw MessageError("config", "is missing or larger than \(BlackiceConfig.maximumBytes / 1024) KiB")
        }
        do {
            _ = try BlackiceConfig(text: config)
        } catch {
            throw MessageError("config", "is not a valid blackice.toml (\(error))")
        }
    }

    /// The configuration of an accepted reply. nil when refused; a reply that `Messages.decode`
    /// returned has already been checked to parse.
    public var configuration: DaemonConfiguration? {
        guard accepted, let generation, let config else { return nil }
        return try? DaemonConfiguration(generation: generation, configText: config)
    }

    /// What the daemon makes of the extension's reply: the configuration, or an error when the
    /// reply is invalid or the registration was refused.
    public static func configuration(from data: Data, now: Date = Date()) throws -> DaemonConfiguration {
        let reply = try Messages.decode(RegisterReply.self, from: data, now: now)
        guard let configuration = reply.configuration else { throw MessageError("registration", "was refused") }
        return configuration
    }
}

/// From the extension to the daemon: a new paused connection, or how one ended. An event carries
/// the generation of the configuration the extension held when it sent the event.
public struct DaemonMessage: CheckedMessage, Equatable {
    public enum Kind: String, Codable, Sendable { case event, verdict }

    public let version: Int
    public let kind: Kind
    public let event: HookEvent?
    public let generation: UInt64?
    public let eventID: String?
    public let verdict: Verdict?

    public static func event(_ event: HookEvent, generation: UInt64) -> DaemonMessage {
        DaemonMessage(version: Messages.version, kind: .event, event: event, generation: generation, eventID: nil, verdict: nil)
    }

    public static func verdict(_ verdict: Verdict, eventID: String) -> DaemonMessage {
        DaemonMessage(version: Messages.version, kind: .verdict, event: nil, generation: nil, eventID: eventID, verdict: verdict)
    }

    public func validate(now: Date) throws {
        switch kind {
        case .event:
            guard let event, eventID == nil, verdict == nil else { throw MessageError("event", "must be the only payload") }
            guard let generation, generation > 0 else { throw MessageError("generation", "must be at least 1") }
            try event.validate(now: now)
        case .verdict:
            guard event == nil, generation == nil, let eventID, verdict != nil else {
                throw MessageError("verdict", "needs event_id and verdict only")
            }
            guard validEventID(eventID) else { throw MessageError("event_id", "must be ev- and 8 hex digits") }
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, kind, event, generation, verdict
        case eventID = "event_id"
    }
}

// MARK: - CLI <-> extension

public struct PendingRequest: CheckedMessage, Equatable {
    public let version: Int
    public init() { version = Messages.version }
    public func validate(now: Date) throws {}
}

/// One paused connection as `blackice pending` shows it. Never carries the token.
public struct PendingSummary: Codable, Equatable, Sendable {
    public let id: String
    public let app: AppReference
    public let path: String?
    public let host: String
    public let ip: String
    public let port: UInt16
    public let secondsLeft: Int
    /// Paused flows waiting on this event: the first one and the repeats.
    public let connections: Int
    /// For an interpreter, the script it runs, as its command line says (HookEvent.App.script).
    public let script: String?

    public init(id: String, app: AppReference, path: String?, host: String, ip: String, port: UInt16,
                secondsLeft: Int, connections: Int, script: String? = nil) {
        self.id = id
        self.app = app
        self.path = path
        self.host = host
        self.ip = ip
        self.port = port
        self.secondsLeft = secondsLeft
        self.connections = connections
        self.script = script
    }

    enum CodingKeys: String, CodingKey {
        case id, app, path, host, ip, port, connections, script
        case secondsLeft = "seconds_left"
    }

    /// A connection with no name is asked about by its address, which is then its host.
    public var hostIsAddress: Bool { host == ip }

    /// "example.com:443 (203.0.113.7)", or "100.66.32.75:22 (no host name)" and
    /// "[fd7a:115c:a1e0::1]:22 (no host name)" for a connection asked about by its address.
    public var destination: String {
        hostIsAddress ? "\(hostAndPort) (no host name)" : "\(hostAndPort) (\(ip))"
    }

    /// "example.com:443", "100.66.32.75:22", "[fd7a:115c:a1e0::1]:22".
    public var hostAndPort: String {
        (hostIsAddress && ip.contains(":") ? "[\(ip)]" : host) + ":\(port)"
    }
}

/// An approval, or a remembered denial, with the seconds it has left.
public struct ApprovalSummary: Codable, Equatable, Sendable {
    public let app: AppReference
    public let host: String
    public let secondsLeft: Int
    /// For an interpreter's answer, the script it covers (ScriptScope).
    public let script: String?
    /// True for an interpreter's answer that covers it running no script it names.
    public let noScript: Bool?

    public init(app: AppReference, host: String, secondsLeft: Int, scope: ScriptScope = .any) {
        self.app = app
        self.host = host
        self.secondsLeft = secondsLeft
        script = scope.script
        noScript = scope == .script(nil) ? true : nil
    }

    public var scope: ScriptScope {
        if let script { return .script(script) }
        return noScript == true ? .script(nil) : .any
    }

    var isValid: Bool {
        app.identity != nil && isNormalDestination(host) && secondsLeft >= 0
            && (script.map(validPath) ?? true) && (noScript == nil || (noScript == true && script == nil))
    }

    enum CodingKeys: String, CodingKey {
        case app, host, script
        case secondsLeft = "seconds_left"
        case noScript = "no_script"
    }
}

extension Mode: Codable {}

/// The configuration the extension decides with: its generation, its mode and the SHA-256 of its
/// blackice.toml text. After saving one, `start` and `mode` wait until the extension names it.
public struct ActiveConfiguration: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let mode: Mode
    public let configSHA256: String

    public init(_ configuration: ProviderConfiguration) {
        generation = configuration.generation
        mode = configuration.mode
        configSHA256 = configuration.configSHA256
    }

    /// Whether the extension decides with `configuration`.
    public func matches(_ configuration: ProviderConfiguration) -> Bool {
        self == ActiveConfiguration(configuration)
    }

    func validate() throws {
        guard generation > 0 else { throw MessageError("active.generation", "must be at least 1") }
        guard configSHA256.utf8.count == 64, configSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MessageError("active.config_sha256", "must be 64 lower-case hex digits")
        }
    }

    enum CodingKeys: String, CodingKey {
        case generation, mode
        case configSHA256 = "config_sha256"
    }
}

public struct PendingReply: CheckedMessage, Equatable {
    public static let maximumEntries = 1024
    /// The largest reply `validate` accepts, encoded: each event at most 1 KiB plus its escaped
    /// path and script, each approval and each denial at most 1 KiB plus its escaped script, and
    /// 1 KiB for the rest. A signing identifier takes at most 255 bytes, a host name 253 and an
    /// address 45, and none of them needs escaping.
    public static let maximumBytes = 1024
        + AskLimits.events * (1024 + 2 * Messages.jsonStringBytes(HookEvent.maximumPathBytes))
        + 2 * ApprovalTable.maximumEntries * (1024 + Messages.jsonStringBytes(HookEvent.maximumPathBytes))

    public let version: Int
    public let events: [PendingSummary]
    public let approvals: [ApprovalSummary]
    /// The app and host pairs denied a moment ago, whose connections are dropped without asking.
    public let denials: [ApprovalSummary]
    /// The configuration the extension decides with now; nil when it holds none.
    public let active: ActiveConfiguration?

    public init(events: [PendingSummary], approvals: [ApprovalSummary], denials: [ApprovalSummary] = [],
                active: ActiveConfiguration? = nil) {
        version = Messages.version
        self.events = events
        self.approvals = approvals
        self.denials = denials
        self.active = active
    }

    /// The same lists, naming the configuration the extension decides with.
    public func deciding(with configuration: ProviderConfiguration?) -> PendingReply {
        PendingReply(events: events, approvals: approvals, denials: denials, active: configuration.map(ActiveConfiguration.init))
    }

    /// At most as many events, approvals and denials as the extension holds, each in the form it
    /// writes.
    public func validate(now: Date) throws {
        guard events.count <= AskLimits.events, approvals.count <= ApprovalTable.maximumEntries,
              denials.count <= ApprovalTable.maximumEntries else {
            throw MessageError("pending", "has too many entries")
        }
        try active?.validate()
        for event in events {
            guard validEventID(event.id), event.app.identity != nil, IPAddress(event.ip)?.description == event.ip,
                  validEventHost(event.host, ip: event.ip), event.secondsLeft >= 0, event.connections >= 0,
                  event.path.map(validPath) ?? true, event.script.map(validPath) ?? true else {
                throw MessageError("events", "has an invalid entry")
            }
        }
        for approval in approvals {
            guard approval.isValid else { throw MessageError("approvals", "has an invalid entry") }
        }
        for denial in denials {
            guard denial.isValid else { throw MessageError("denials", "has an invalid entry") }
        }
    }
}

/// An answer to the extension. With `authorization` "touch_id", `blackice approve` or `deny` has
/// just confirmed a person with Touch ID. With "token", the daemon answers for a hook with the
/// event's one-time token; only the daemon sends these, and the extension takes them only on the
/// connection of the daemon it registered.
public struct AnswerRequest: CheckedMessage, Equatable {
    public enum Kind: String, Codable, Sendable { case approve, deny }
    public enum Authorization: String, Codable, Sendable {
        case token
        case touchID = "touch_id"
    }

    public let version: Int
    public let kind: Kind
    public let app: AppReference
    public let host: String
    /// approve only: how long the approval lasts, 1 s to 24 h.
    public let seconds: Int?
    public let authorization: Authorization
    public let token: String?
    /// touch_id only: the one script of an interpreter the answer covers (`--script`); with none,
    /// a person's answer covers all of them. An answer with a token covers its event's script.
    public let script: String?

    public init(kind: Kind, app: AppIdentity, host: String, seconds: Int?, token: String?, script: String? = nil) {
        version = Messages.version
        self.kind = kind
        self.app = AppReference(app)
        self.host = host
        self.seconds = seconds
        self.authorization = token == nil ? .touchID : .token
        self.token = token
        self.script = script
    }

    public var identity: AppIdentity? { app.identity }

    /// What a person's answer covers; one with a token takes its event's instead (AskState.answer).
    public var scope: ScriptScope { script.map { .script($0) } ?? .any }

    public func validate(now: Date) throws {
        guard app.identity != nil else { throw MessageError("app", "needs a valid signing_id (and team_id) or a cdhash, not both") }
        guard isNormalDestination(host) else {
            throw MessageError("host", "must be a normalized host name or IP address")
        }
        switch kind {
        case .approve:
            guard let seconds, (1...ApprovalTable.maximumSeconds).contains(seconds) else {
                throw MessageError("seconds", "must be from 1 to \(ApprovalTable.maximumSeconds)")
            }
        case .deny:
            guard seconds == nil else { throw MessageError("seconds", "is for approve only") }
        }
        switch authorization {
        case .token:
            guard let token, validEventToken(token) else { throw MessageError("token", "must be 43 base64url characters") }
        case .touchID:
            guard token == nil else { throw MessageError("token", "must be absent with touch_id") }
        }
        if let script {
            guard authorization == .touchID else { throw MessageError("script", "is for touch_id only") }
            guard ScriptScope.canName(script) else {
                throw MessageError("script", "must be an absolute path or -m module, with no control characters")
            }
        }
    }
}

public struct AnswerReply: CheckedMessage, Equatable {
    public enum Status: String, Codable, Sendable { case done, refused }

    public let version: Int
    public let status: Status
    /// A short code: approved, denied, token_unknown, token_spent, token_expired, token_mismatch,
    /// not_the_daemon.
    public let reason: String
    public let message: String
    /// Events this answer resolved.
    public let events: [String]
    /// Paused flows it released (allowed or dropped).
    public let released: Int

    public init(status: Status, reason: String, message: String, events: [String] = [], released: Int = 0) {
        version = Messages.version
        self.status = status
        self.reason = reason
        self.message = message
        self.events = events
        self.released = released
    }

    public func validate(now: Date) throws {
        guard reason.utf8.count <= 64, reason.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else {
            throw MessageError("reason", "must be a short code")
        }
        guard message.utf8.count <= 1024, !message.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw MessageError("message", "is too long or has control characters")
        }
        guard events.count <= PendingReply.maximumEntries, events.allSatisfy(validEventID), released >= 0 else {
            throw MessageError("events", "has an invalid entry")
        }
    }
}
