import Foundation
import Security

/// One paused connection, as the extension sends it to the daemon. The host and app fields come
/// from whoever opened the connection: a hook must treat them as data, never as instructions.
///
/// The token stays with the extension and the daemon. A hook gets `input`, which is everything
/// else; the daemon answers for it with the token (see `HookAnswer`).
public struct HookEvent: Codable, Equatable, Sendable {
    /// Signed code has a signing identifier (and a Team ID unless it is Apple platform code).
    /// Ad hoc signed code has neither and is named by its cdhash instead. Exactly one of
    /// `signingID` and `cdhash` is set.
    public struct App: Codable, Equatable, Sendable {
        public let signingID: String?
        /// nil for Apple platform code, which has no Team ID, and for ad hoc code.
        public let teamID: String?
        /// 40 lower-case hex digits, only for ad hoc code. A rebuild changes it.
        public let cdhash: String?
        public let path: String?

        public init(signingID: String?, teamID: String?, cdhash: String? = nil, path: String?) {
            self.signingID = signingID
            self.teamID = teamID
            self.cdhash = cdhash
            self.path = path
        }

        public init(_ identity: AppIdentity, path: String?) {
            let reference = AppReference(identity)
            self.init(signingID: reference.signingID, teamID: reference.teamID, cdhash: reference.cdhash, path: path)
        }

        /// nil unless exactly one form is present and valid.
        public var identity: AppIdentity? {
            AppReference(signingID: signingID, teamID: teamID, cdhash: cdhash).identity
        }

        enum CodingKeys: String, CodingKey {
            case signingID = "signing_id"
            case teamID = "team_id"
            case cdhash
            case path
        }
    }

    /// Always "connection" for now.
    public let event: String
    public let id: String
    /// Good for one answer to this event. Never given to a hook.
    public let token: String
    public let app: App
    /// The host name, when the system or the TLS ClientHello gave one.
    public let host: String?
    public let ip: String
    public let port: UInt16
    /// After this instant the connection is dropped.
    public let deadline: Date

    public init(event: String = "connection", id: String, token: String, app: App, host: String?,
                ip: String, port: UInt16, deadline: Date) {
        self.event = event
        self.id = id
        self.token = token
        self.app = app
        self.host = host
        self.ip = ip
        self.port = port
        self.deadline = deadline
    }

    /// A new event with a fresh ID and token.
    public static func connection(app: App, host: String?, ip: String, port: UInt16, deadline: Date) throws -> HookEvent {
        HookEvent(id: "ev-" + (try randomHex(bytes: 4)), token: try EventToken.generate(),
                  app: app, host: host, ip: ip, port: port, deadline: deadline)
    }

    /// What a hook reads: the event without its token.
    public struct Input: Codable, Equatable, Sendable {
        public let event: String
        public let id: String
        public let app: App
        public let host: String?
        public let ip: String
        public let port: UInt16
        public let deadline: Date

        /// One line of JSON with sorted keys: the hook's stdin and its event file.
        public func jsonData() throws -> Data { try encodeLine(self) }

        public static func decode(_ data: Data) throws -> Input { try decodeJSON(Input.self, data) }
    }

    public var input: Input {
        Input(event: event, id: id, app: app, host: host, ip: ip, port: port, deadline: deadline)
    }

    /// One line of JSON with sorted keys, so the same event always encodes the same way. This form
    /// holds the token: it is for XPC between the extension and the daemon, never for a hook.
    public func jsonData() throws -> Data { try encodeLine(self) }

    public static func decode(_ data: Data) throws -> HookEvent { try decodeJSON(HookEvent.self, data) }

    public static let maximumPathBytes = 1024

    /// Checks every field the way the extension builds them. The daemon calls this on each event
    /// it receives, before logging it or running a hook.
    public func validate(now: Date, maximumWait: TimeInterval = TimeInterval(BlackiceConfig.timeoutRange.upperBound)) throws {
        guard event == "connection" else { throw MessageError("event", "must be \"connection\"") }
        guard validEventID(id) else { throw MessageError("id", "must be ev- and 8 hex digits") }
        guard validEventToken(token) else { throw MessageError("token", "must be 43 base64url characters") }
        guard app.identity != nil else {
            throw MessageError("app", "needs a valid signing_id (and team_id) or a cdhash, not both")
        }
        if let path = app.path, !validPath(path) { throw MessageError("app.path", "is too long or has control characters") }
        guard let host, normalizeHost(host) == host else { throw MessageError("host", "must be a normalized host name") }
        guard let address = IPAddress(ip), address.description == ip else { throw MessageError("ip", "must be an IP address") }
        guard port > 0 else { throw MessageError("port", "must not be 0") }
        let left = deadline.timeIntervalSince(now)
        guard left > -5, left <= maximumWait + 5 else { throw MessageError("deadline", "is not within the timeout") }
    }
}

private func encodeLine(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func decodeJSON<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}

/// "ev-" and 8 lower-case hex digits, as `HookEvent.connection` makes them.
public func validEventID(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return bytes.count == 11 && text.hasPrefix("ev-")
        && bytes[3...].allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

/// 43 base64url characters, as `EventToken.generate` makes them.
public func validEventToken(_ text: String) -> Bool {
    text.utf8.count == 43 && text.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }
}

/// At most `HookEvent.maximumPathBytes`, no control characters.
func validPath(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= HookEvent.maximumPathBytes
        && !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

public enum EventToken {
    public static let byteCount = 32

    public struct RandomFailure: Error, Equatable { public let status: Int32 }

    /// 32 bytes from SecRandomCopyBytes, base64url without padding: 43 characters.
    public static func generate() throws -> String {
        base64url(try randomBytes(byteCount))
    }

    /// Compares in time that depends only on the lengths, not on where the first difference is.
    public static func matches(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8), b = Array(expected.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func randomBytes(_ count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else { throw EventToken.RandomFailure(status: status) }
    return bytes
}

func randomHex(bytes count: Int) throws -> String {
    try randomBytes(count).map { String(format: "%02x", $0) }.joined()
}
