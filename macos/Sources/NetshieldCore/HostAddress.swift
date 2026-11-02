import Darwin
import Foundation

// Checking a host name against the address a flow connects to (phase 2).
//
// Rules and approvals name hosts, but an app picks both the name macOS attaches to a flow (or
// the TLS server name it sends) and the address it connects to. So before a rule or an approval
// counts, the host is resolved with the system resolver and the flow's remote address must be
// among the answers. Answers are cached for a short, fixed time. A mismatch is not an error: the
// rule or approval simply does not match, so ask mode asks and block-all drops, and the verdict's
// reason says "address_mismatch".
//
// Known limits: the system resolver may give this lookup different answers than it gave the app
// (round-robin and CDN answers that change between queries), which shows up as a mismatch; and
// the check proves only that the name resolves to that address now, not who controls the name.

/// An IPv4 or IPv6 address. IPv4-mapped IPv6 addresses become IPv4, so the two spellings of
/// one address compare equal. Zone suffixes ("%en0") are ignored.
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6, network order.
    public let bytes: [UInt8]

    public init?(_ text: String) {
        var text = text
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        guard !text.isEmpty, text.utf8.count <= 45, !text.utf8.contains(0) else { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v4) { Array($0) })
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            return nil
        }
    }

    public init?(bytes: [UInt8]) {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            self.bytes = Array(bytes[12...])
        } else if bytes.count == 4 || bytes.count == 16 {
            self.bytes = bytes
        } else {
            return nil
        }
    }

    public var description: String {
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let written = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard written != nil else { return "invalid" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The system resolver, or a fake one in tests.
public protocol HostResolving: Sendable {
    /// The addresses `host` resolves to now, or nil when the lookup failed. Blocks.
    func resolve(_ host: String) -> [IPAddress]?
}

/// getaddrinfo, which goes through the system resolver (mDNSResponder) like the apps do.
/// Compiled and tested only against "localhost"; in the extension it runs off the flow path.
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(_ host: String) -> [IPAddress]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    var v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if let ip = IPAddress(bytes: withUnsafeBytes(of: &v4) { Array($0) }) { addresses.append(ip) }
                case AF_INET6:
                    var v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if let ip = IPAddress(bytes: withUnsafeBytes(of: &v6) { Array($0) }) { addresses.append(ip) }
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}

public enum AddressCheck: Equatable, Sendable {
    /// The flow's address is among the host's current answers.
    case match
    /// It is not, the lookup failed, or the flow has no address.
    case mismatch
    /// Not looked up yet, or the cached answers expired: resolve first.
    case unknown
}

/// The host's answers from the system resolver, kept for a short fixed time. Thread-safe.
public final class HostAddressCache: @unchecked Sendable {
    /// Provisional: short enough to follow DNS changes, long enough that a burst of connections
    /// to one host costs one lookup.
    public static let defaultTTL: TimeInterval = 30
    public static let defaultLimit = 1024

    public let resolver: any HostResolving
    public let ttl: TimeInterval
    private let limit: Int
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [String: (addresses: Set<IPAddress>, expires: TimeInterval)] = [:]

    /// `clock` returns seconds on a monotonic scale; the default is the system uptime.
    public init(resolver: any HostResolving, ttl: TimeInterval = defaultTTL, limit: Int = defaultLimit,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.resolver = resolver
        self.ttl = ttl
        self.limit = limit
        self.clock = clock
    }

    /// Never blocks. `host` must be normalized.
    public func check(host: String, address: IPAddress?) -> AddressCheck {
        guard let cached = cached(host) else { return .unknown }
        return Self.check(address, against: cached)
    }

    public static func check(_ address: IPAddress?, against answers: Set<IPAddress>) -> AddressCheck {
        guard let address else { return .mismatch }
        return answers.contains(address) ? .match : .mismatch
    }

    /// The current answers for `host`, or nil when there are none or they expired.
    public func cached(_ host: String) -> Set<IPAddress>? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[host], entry.expires > clock() else { return nil }
        return entry.addresses
    }

    /// Resolves `host`, blocking, and stores the answers. A failed lookup is stored as no answers,
    /// which every address mismatches. Call it off the flow path.
    @discardableResult
    public func lookUp(_ host: String) -> Set<IPAddress> {
        let answers = Set(resolver.resolve(host) ?? [])
        store(host, answers)
        return answers
    }

    public func store(_ host: String, _ answers: Set<IPAddress>) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if entries.count >= limit, entries[host] == nil {
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        }
        entries[host] = (answers, now + ttl)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

/// Flows that wait for one host's lookup, so a burst of connections to a host starts one lookup.
public struct LookupWaiters<Flow> {
    public let limit: Int
    private var waiting: [String: [Flow]] = [:]
    public private(set) var count = 0

    public init(limit: Int = 1024) { self.limit = limit }

    public enum Added: Equatable {
        /// The first flow for this host: the caller starts the lookup.
        case startLookup
        /// A lookup for this host is already running.
        case waiting
        /// Too many flows are waiting; the caller drops this one.
        case full
    }

    public mutating func add(_ flow: Flow, host: String) -> Added {
        guard count < limit else { return .full }
        count += 1
        if waiting[host] != nil {
            waiting[host]?.append(flow)
            return .waiting
        }
        waiting[host] = [flow]
        return .startLookup
    }

    /// The flows waiting for `host`, removed.
    public mutating func finish(_ host: String) -> [Flow] {
        let flows = waiting.removeValue(forKey: host) ?? []
        count -= flows.count
        return flows
    }

    public mutating func removeAll() -> [Flow] {
        let flows = waiting.values.flatMap { $0 }
        waiting.removeAll()
        count = 0
        return flows
    }
}
