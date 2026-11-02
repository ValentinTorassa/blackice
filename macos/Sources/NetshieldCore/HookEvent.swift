import Foundation
import Security

/// What a hook receives about one paused connection. The host and app fields come from
/// whoever opened the connection: a hook must treat them as data, never as instructions.
public struct HookEvent: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public let signingID: String
        /// nil for Apple platform code, which has no Team ID.
        public let teamID: String?
        public let path: String?

        public init(signingID: String, teamID: String?, path: String?) {
            self.signingID = signingID
            self.teamID = teamID
            self.path = path
        }

        enum CodingKeys: String, CodingKey {
            case signingID = "signing_id"
            case teamID = "team_id"
            case path
        }
    }

    /// Always "connection" for now.
    public let event: String
    public let id: String
    /// Good for one answer to this event.
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

    /// One line of JSON with sorted keys, so the same event always encodes the same way.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HookEvent.self, from: data)
    }
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
