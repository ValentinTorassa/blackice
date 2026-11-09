import Darwin
import Foundation

// Checking a host name against the address a flow connects to (phase 2).
//
// Rules and approvals name hosts, but an app picks both the name macOS attaches to a flow (or
// the TLS server name it sends) and the address it connects to. So before a rule or an approval
// counts, the host is resolved with the system resolver and the flow's remote address must be
// among the answers. Answers are cached for a short, fixed time. A mismatch is not an error: the
// rule or approval simply does not match, so the flow is dropped with "address_mismatch" as the
// verdict's reason. Ask mode asks only about a pair nothing names, for the app's next connection.
//
// Known limits: the system resolver may give this lookup different answers than it gave the app
// (round-robin and CDN answers that change between queries), which shows up as a mismatch; and
// the check proves only that the name resolves to that address now, not who controls the name.

/// An IPv4 or IPv6 address. IPv4-mapped IPv6 addresses become IPv4, so the two spellings of
/// one address compare equal. A link-local IPv6 address (fe80::/10) can name a different host
/// on each link, so it keeps its interface (the zone, "%en0" or "%4") as `scope`, and two of
/// them are equal only on the same interface. Other addresses ignore a zone.
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6, network order.
    public let bytes: [UInt8]
    /// The interface index of a link-local IPv6 address, 0 when none was given or the interface
    /// is unknown. Always 0 for other addresses.
    public let scope: UInt32

    public init?(_ text: String) {
        var address = text
        var zone: String?
        if let percent = text.firstIndex(of: "%") {
            address = String(text[..<percent])
            zone = String(text[text.index(after: percent)...])
        }
        guard !address.isEmpty, address.utf8.count <= 45, !text.utf8.contains(0) else { return nil }
        if let zone, zone.isEmpty || zone.utf8.count >= Int(IFNAMSIZ) { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v4) { Array($0) })
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v6) { Array($0) }, scope: zone.map(Self.interfaceIndex) ?? 0)
        } else {
            return nil
        }
    }

    public init?(bytes: [UInt8], scope: UInt32 = 0) {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            self.bytes = Array(bytes[12...])
        } else if bytes.count == 4 || bytes.count == 16 {
            self.bytes = bytes
        } else {
            return nil
        }
        self.scope = Self.isLinkLocal(self.bytes) ? scope : 0
    }

    /// An address as a person writes it in a rule or after `--host`. Stricter than init(_:):
    /// IPv4, alone or at the end of an IPv6 address, is four decimal numbers from 0 to 255 with no
    /// leading zeros, since "010.0.0.1", "10.1" and "0x0a.0.0.1" mean other addresses to other
    /// parsers (inet_pton takes the first as 10.0.0.1). A zone ("%en0") goes only with a
    /// link-local IPv6 address. Any IPv6 spelling inet_pton takes is accepted otherwise.
    /// A static function, so `IPAddress.init` stays unambiguous.
    public static func strict(_ text: String) -> IPAddress? {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let address = parts[0]
        if address.contains(":") {
            // Hex digits, ':' and '.'.
            guard address.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46
            }) else { return nil }
            if let colon = address.lastIndex(of: ":"), address[colon...].contains("."),
               !isStrictIPv4(address[address.index(after: colon)...]) { return nil }
        } else {
            guard parts.count == 1, isStrictIPv4(address) else { return nil }
        }
        guard let parsed = IPAddress(text), parts.count == 1 || parsed.isLinkLocal else { return nil }
        return parsed
    }

    /// Four decimal numbers from 0 to 255, separated by dots, with no leading zeros.
    static func isStrictIPv4(_ text: Substring) -> Bool {
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false)
        return numbers.count == 4 && numbers.allSatisfy { number in
            (1...3).contains(number.utf8.count) && number.utf8.allSatisfy { (48...57).contains($0) }
                && (number == "0" || !number.hasPrefix("0")) && Int(number).map { $0 <= 255 } == true
        }
    }

    /// 127.0.0.0/8 and ::1. An IPv4-mapped loopback address is IPv4 here already.
    public var isLoopback: Bool {
        bytes.count == 4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// 224.0.0.0/4, 255.255.255.255 and ff00::/8. A subnet's broadcast address (10.0.0.255 on a
    /// /24, say) is not among them: telling it apart needs the interface's netmask.
    public var isMulticastOrBroadcast: Bool {
        bytes.count == 4 ? bytes[0] & 0xF0 == 0xE0 || bytes == [255, 255, 255, 255] : bytes[0] == 0xFF
    }

    /// fe80::/10.
    public var isLinkLocal: Bool { Self.isLinkLocal(bytes) }

    /// False for a link-local address whose interface is not known: it may be any host on any
    /// link, so it never shows that a flow reaches a given host.
    public var isCheckable: Bool { !isLinkLocal || scope != 0 }

    /// A link-local address ends in "%" and its interface index, which init(_:) reads back.
    public var description: String {
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let written = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard written != nil else { return "invalid" }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return scope == 0 ? text : "\(text)%\(scope)"
    }

    private static func isLinkLocal(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }

    /// A zone is an interface index or an interface name; 0 when there is no such interface.
    private static func interfaceIndex(_ zone: String) -> UInt32 {
        if zone.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return UInt32(zone) ?? 0 }
        return if_nametoindex(zone)
    }
}

/// How events, pending entries and approvals name a destination: a host name as normalizeHost
/// returns it, or an IP address as `IPAddress.description` prints it (lower case and compressed
/// as in RFC 5952 for IPv6; a link-local address with its interface index after "%"). The address
/// is read with `IPAddress.strict`. nil for anything else, and for a link-local address whose
/// interface is not known, which could be any host on any link.
public func normalizeDestination(_ raw: String) -> String? {
    if let host = normalizeHost(raw) { return host }
    guard let address = IPAddress.strict(raw), address.isCheckable else { return nil }
    return address.description
}

/// Whether `text` is a destination already in the form `normalizeDestination` returns.
public func isNormalDestination(_ text: String) -> Bool {
    if normalizeHost(text) == text { return true }
    guard let address = IPAddress(text) else { return false }
    return address.isCheckable && address.description == text
}

/// An address entry in a rule's `hosts`: one IPv4 or IPv6 address, or a CIDR range of them.
/// Written strictly (`IPAddress.strict`), with a decimal prefix and no bits set after it, so
/// "10.0.0.5/8" is refused rather than read as 10.0.0.0/8. A rule names no interface: a
/// link-local entry matches its addresses on every interface.
public struct AddressRange: Equatable, Sendable {
    public let source: String
    /// 4 bytes for IPv4, 16 for IPv6, network order, zero after the prefix.
    public let network: [UInt8]
    /// 1 to 32 for IPv4, 1 to 128 for IPv6.
    public let prefix: Int

    public enum Problem: Error, Equatable {
        /// Not an address in the strict form.
        case notAnAddress
        /// A zone ("%en0") after the address.
        case zone
        /// An IPv4-mapped IPv6 address (::ffff:a.b.c.d), which flows report as IPv4.
        case mapped
        /// A prefix that is not a decimal number within the family's bounds.
        case prefix(maximum: Int)
        /// Bits set after the prefix; the range that was probably meant.
        case hostBits(network: String)
        /// 0.0.0.0/0 or ::/0, which `*` says plainly.
        case everything
    }

    /// Whether a `hosts` entry is meant as an address rather than a host name: it has ':' or '/',
    /// or only digits and dots, none of which a host name can be (normalizeHost refuses a name
    /// whose last label is a number).
    public static func looksLikeAddress(_ text: String) -> Bool {
        text.contains(":") || text.contains("/") || (!text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
    }

    public static func parse(_ text: String) -> Result<AddressRange, Problem> {
        if text.contains("%") { return .failure(.zone) }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let written = String(parts[0])
        guard let address = IPAddress.strict(written) else { return .failure(.notAnAddress) }
        if written.contains(":") && address.bytes.count == 4 { return .failure(.mapped) }
        let bits = address.bytes.count * 8
        var prefix = bits
        if parts.count == 2 {
            let digits = parts[1]
            guard (1...3).contains(digits.utf8.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  digits == "0" || !digits.hasPrefix("0"), let number = Int(digits), number <= bits else {
                return .failure(.prefix(maximum: bits))
            }
            prefix = number
        }
        if prefix == 0 { return .failure(.everything) }
        let network = Self.masked(address.bytes, prefix)
        guard network == address.bytes else {
            let start = IPAddress(bytes: network).map(\.description) ?? "?"
            return .failure(.hostBits(network: "\(start)/\(prefix)"))
        }
        return .success(AddressRange(source: text, network: network, prefix: prefix))
    }

    private init(source: String, network: [UInt8], prefix: Int) {
        self.source = source
        self.network = network
        self.prefix = prefix
    }

    /// The range in one spelling, for finding the same range written twice.
    public var canonical: String {
        (IPAddress(bytes: network).map(\.description) ?? "?") + "/\(prefix)"
    }

    /// Whether `address` is in the range. The interface of a link-local address does not count.
    public func contains(_ address: IPAddress) -> Bool {
        address.bytes.count == network.count && Self.masked(address.bytes, prefix) == network
    }

    /// `bytes` with every bit after the first `prefix` cleared.
    private static func masked(_ bytes: [UInt8], _ prefix: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let kept = min(max(prefix - index * 8, 0), 8)
            return kept == 8 ? byte : byte & ~(UInt8(0xFF) >> kept)
        }
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
                    // The scope ID is the interface of a link-local answer (from mDNS, say).
                    let socket = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var v6 = socket.sin6_addr
                    if let ip = IPAddress(bytes: withUnsafeBytes(of: &v6) { Array($0) }, scope: socket.sin6_scope_id) {
                        addresses.append(ip)
                    }
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

    /// `clock` returns seconds on a monotonic scale; the default counts sleep (continuousSeconds).
    public init(resolver: any HostResolving, ttl: TimeInterval = defaultTTL, limit: Int = defaultLimit,
                clock: @escaping @Sendable () -> TimeInterval = { continuousSeconds() }) {
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

    /// Answers this old or older that miss an address are looked up again before they count as a
    /// mismatch. Younger ones are what the resolver says now, so a burst still costs one lookup.
    public static let refreshAfter: TimeInterval = 2

    /// `check`, for a flow that can wait for a lookup: answers older than `refreshAfter` that miss
    /// its address read as not looked up, so the caller looks the host up again and decides on
    /// what the resolver says now. CDNs answer with TTLs of seconds and rotate their addresses: on
    /// 8 November 2026 outlook.office365.com had A records of 2 to 4 s and 13 answer sets in
    /// 3 minutes, and the first address of half its answers was not in answers up to 30 s old.
    /// A failed lookup (no answers) and an address that cannot be checked stay a mismatch.
    public func checkOrRefresh(host: String, address: IPAddress?) -> AddressCheck {
        lock.lock()
        let entry = entries[host]
        let now = clock()
        lock.unlock()
        guard let entry, entry.expires > now else { return .unknown }
        let result = Self.check(address, against: entry.addresses)
        let lookedUpAt = entry.expires - ttl
        if result == .mismatch, !entry.addresses.isEmpty, address?.isCheckable == true,
           now - lookedUpAt >= Self.refreshAfter {
            return .unknown
        }
        return result
    }

    /// A link-local address matches only an answer on the same interface, and never when its
    /// interface is not known.
    public static func check(_ address: IPAddress?, against answers: Set<IPAddress>) -> AddressCheck {
        guard let address, address.isCheckable else { return .mismatch }
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
