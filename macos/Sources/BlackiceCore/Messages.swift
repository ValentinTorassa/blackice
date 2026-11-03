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
    var version: Int { get }
    func validate(now: Date) throws
}

public enum Messages {
    /// Bumped on any change to a message; both ends must agree.
    public static let version = 1
    /// Enough for a full pending list; anything larger is refused before decoding.
    public static let maximumBytes = 262_144

    public static func encode(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(message)
    }

    public static func decode<Message: CheckedMessage>(_ type: Message.Type, from data: Data, now: Date = Date()) throws -> Message {
        guard !data.isEmpty, data.count <= maximumBytes else { throw MessageError("message", "is empty or too large") }
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

/// The daemon asks to receive events on this connection.
public struct RegisterRequest: CheckedMessage, Equatable {
    public let version: Int
    public init() { version = Messages.version }
    public func validate(now: Date) throws {}
}

public struct RegisterReply: CheckedMessage, Equatable {
    public let version: Int
    public let accepted: Bool
    public init(accepted: Bool) {
        version = Messages.version
        self.accepted = accepted
    }
    public func validate(now: Date) throws {}
}

/// From the extension to the daemon: a new paused connection, or how one ended.
public struct DaemonMessage: CheckedMessage, Equatable {
    public enum Kind: String, Codable, Sendable { case event, verdict }

    public let version: Int
    public let kind: Kind
    public let event: HookEvent?
    public let eventID: String?
    public let verdict: Verdict?

    public static func event(_ event: HookEvent) -> DaemonMessage {
        DaemonMessage(version: Messages.version, kind: .event, event: event, eventID: nil, verdict: nil)
    }

    public static func verdict(_ verdict: Verdict, eventID: String) -> DaemonMessage {
        DaemonMessage(version: Messages.version, kind: .verdict, event: nil, eventID: eventID, verdict: verdict)
    }

    public func validate(now: Date) throws {
        switch kind {
        case .event:
            guard let event, eventID == nil, verdict == nil else { throw MessageError("event", "must be the only payload") }
            try event.validate(now: now)
        case .verdict:
            guard event == nil, let eventID, verdict != nil else { throw MessageError("verdict", "needs event_id and verdict only") }
            guard validEventID(eventID) else { throw MessageError("event_id", "must be ev- and 8 hex digits") }
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, kind, event, verdict
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

    public init(id: String, app: AppReference, path: String?, host: String, ip: String, port: UInt16,
                secondsLeft: Int, connections: Int) {
        self.id = id
        self.app = app
        self.path = path
        self.host = host
        self.ip = ip
        self.port = port
        self.secondsLeft = secondsLeft
        self.connections = connections
    }

    enum CodingKeys: String, CodingKey {
        case id, app, path, host, ip, port, connections
        case secondsLeft = "seconds_left"
    }
}

public struct ApprovalSummary: Codable, Equatable, Sendable {
    public let app: AppReference
    public let host: String
    public let secondsLeft: Int

    public init(app: AppReference, host: String, secondsLeft: Int) {
        self.app = app
        self.host = host
        self.secondsLeft = secondsLeft
    }

    enum CodingKeys: String, CodingKey {
        case app, host
        case secondsLeft = "seconds_left"
    }
}

public struct PendingReply: CheckedMessage, Equatable {
    public static let maximumEntries = 1024

    public let version: Int
    public let events: [PendingSummary]
    public let approvals: [ApprovalSummary]

    public init(events: [PendingSummary], approvals: [ApprovalSummary]) {
        version = Messages.version
        self.events = events
        self.approvals = approvals
    }

    public func validate(now: Date) throws {
        guard events.count <= Self.maximumEntries, approvals.count <= Self.maximumEntries else {
            throw MessageError("pending", "has too many entries")
        }
        for event in events {
            guard validEventID(event.id), event.app.identity != nil, normalizeHost(event.host) == event.host,
                  IPAddress(event.ip) != nil, event.secondsLeft >= 0, event.connections > 0,
                  event.path.map(validPath) ?? true else { throw MessageError("events", "has an invalid entry") }
        }
        for approval in approvals {
            guard approval.app.identity != nil, normalizeHost(approval.host) == approval.host,
                  approval.secondsLeft >= 0 else { throw MessageError("approvals", "has an invalid entry") }
        }
    }
}

/// `blackice approve` or `deny`. With `authorization` "token" the hook presents the event's
/// one-time token; with "touch_id" the signed CLI has just confirmed a person with Touch ID.
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

    public init(kind: Kind, app: AppIdentity, host: String, seconds: Int?, token: String?) {
        version = Messages.version
        self.kind = kind
        self.app = AppReference(app)
        self.host = host
        self.seconds = seconds
        self.authorization = token == nil ? .touchID : .token
        self.token = token
    }

    public var identity: AppIdentity? { app.identity }

    public func validate(now: Date) throws {
        guard app.identity != nil else { throw MessageError("app", "needs a valid signing_id (and team_id) or a cdhash, not both") }
        guard normalizeHost(host) == host else { throw MessageError("host", "must be a normalized host name") }
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
    }
}

public struct AnswerReply: CheckedMessage, Equatable {
    public enum Status: String, Codable, Sendable { case done, refused }

    public let version: Int
    public let status: Status
    /// A short code: approved, denied, token_unknown, token_spent, token_expired, token_mismatch.
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
