import Foundation

// DNS messages, as far as blackice reads them: the header, one question, and the answer
// section's A, AAAA and CNAME records (RFC 1035 section 4.1, compression in 4.1.4). The
// extension reads them on the system resolver's DNS flows to learn which names an address was
// given for (DNSFlowReader, DNSNameTable). Every byte of those flows passes unchanged whatever
// the parser makes of it, so parsing is best effort: anything malformed, truncated, too large or
// not understood is nil, and nil means "learn nothing".

public enum DNSRecordType {
    public static let a: UInt16 = 1
    public static let cname: UInt16 = 5
    public static let aaaa: UInt16 = 28
}

/// The Internet class, the only one blackice learns from.
public let dnsClassIN: UInt16 = 1

public struct DNSQuestion: Hashable, Sendable {
    /// Normalized with `normalizeHost`.
    public let name: String
    public let type: UInt16
    public let recordClass: UInt16

    public init(name: String, type: UInt16, recordClass: UInt16 = dnsClassIN) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
    }
}

public struct DNSRecord: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        /// An A or AAAA record of class IN.
        case address(IPAddress)
        /// A CNAME record of class IN whose target is a host name, normalized.
        case alias(String)
        /// Anything else, skipped.
        case other
    }

    /// Normalized, or nil when the owner is not a host name `normalizeHost` accepts.
    public let name: String?
    public let type: UInt16
    public let recordClass: UInt16
    /// Seconds. A TTL with the top bit set reads as 0 (RFC 2181 section 8).
    public let ttl: UInt32
    public let value: Value
}

/// What one response teaches: `name`, as the question asked it, resolves to `address`.
public struct DNSLearned: Hashable, Sendable {
    public let name: String
    public let address: IPAddress
    /// Seconds: the smallest TTL along the CNAME chain and the address record.
    public let ttl: UInt32

    public init(name: String, address: IPAddress, ttl: UInt32) {
        self.name = name
        self.address = address
        self.ttl = ttl
    }
}

/// A CNAME on the chain from a question's name: `name` is an alias of `target` for `ttl` seconds.
public struct DNSAlias: Hashable, Sendable {
    public let name: String
    public let target: String
    public let ttl: UInt32

    public init(name: String, target: String, ttl: UInt32) {
        self.name = name
        self.target = target
        self.ttl = ttl
    }
}

public struct DNSMessage: Equatable, Sendable {
    /// The largest message a 2-byte length (TCP) or a UDP datagram can carry.
    public static let maximumBytes = 65_535
    /// More answer records than this and the message is not read.
    public static let maximumAnswers = 128
    /// Compression pointers followed within one name.
    public static let maximumJumps = 16
    /// CNAME records followed from the question's name.
    public static let maximumAliases = 16

    public let id: UInt16
    public let isResponse: Bool
    public let opcode: UInt8
    public let truncated: Bool
    public let responseCode: UInt8
    /// Exactly one question; any other count is not read.
    public let question: DNSQuestion
    /// The answer section of a response; empty for a query. The authority and additional
    /// sections are never read.
    public let answers: [DNSRecord]

    /// nil for anything that is not a well-formed message with one question whose name is a
    /// host name, within `maximumBytes` and `maximumAnswers`. Bytes after the answer section
    /// are ignored.
    public init?(_ data: Data) {
        guard data.count >= 12, data.count <= Self.maximumBytes else { return nil }
        let bytes = [UInt8](data)
        func uint16(_ index: Int) -> UInt16 { UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) }
        let flags = uint16(2)
        guard uint16(4) == 1 else { return nil }
        let answerCount = Int(uint16(6))
        guard let (questionName, questionEnd) = Self.readName(bytes, at: 12),
              let name = questionName, questionEnd + 4 <= bytes.count else { return nil }
        id = uint16(0)
        isResponse = flags & 0x8000 != 0
        opcode = UInt8((flags >> 11) & 0x0F)
        truncated = flags & 0x0200 != 0
        responseCode = UInt8(flags & 0x000F)
        question = DNSQuestion(name: name, type: uint16(questionEnd), recordClass: uint16(questionEnd + 2))
        guard isResponse else {
            answers = []
            return
        }
        guard answerCount <= Self.maximumAnswers else { return nil }
        var records: [DNSRecord] = []
        var cursor = questionEnd + 4
        for _ in 0..<answerCount {
            guard let (owner, ownerEnd) = Self.readName(bytes, at: cursor), ownerEnd + 10 <= bytes.count else { return nil }
            let type = uint16(ownerEnd), recordClass = uint16(ownerEnd + 2)
            let rawTTL = UInt32(uint16(ownerEnd + 4)) << 16 | UInt32(uint16(ownerEnd + 6))
            let dataStart = ownerEnd + 10
            let dataEnd = dataStart + Int(uint16(ownerEnd + 8))
            guard dataEnd <= bytes.count else { return nil }
            var value = DNSRecord.Value.other
            if recordClass == dnsClassIN {
                switch type {
                case DNSRecordType.a, DNSRecordType.aaaa:
                    guard dataEnd - dataStart == (type == DNSRecordType.a ? 4 : 16),
                          let address = IPAddress(bytes: Array(bytes[dataStart..<dataEnd])) else { return nil }
                    value = .address(address)
                case DNSRecordType.cname:
                    guard let (target, targetEnd) = Self.readName(bytes, at: dataStart), targetEnd == dataEnd else { return nil }
                    value = target.map { .alias($0) } ?? .other
                default:
                    break
                }
            }
            records.append(DNSRecord(name: owner, type: type, recordClass: recordClass,
                                     ttl: rawTTL & 0x8000_0000 == 0 ? rawTTL : 0, value: value))
            cursor = dataEnd
        }
        answers = records
    }

    /// The question's name against each address at the end of its CNAME chain, from a
    /// successful, untruncated response to an A or AAAA question of class IN. Records that are
    /// not on the chain from the question's name teach nothing, and a CNAME target is never
    /// recorded as a name of its own. Empty when there is nothing to learn.
    public var learned: [DNSLearned] {
        guard let chain else { return [] }
        let ttl = chain.links.map(\.ttl).min() ?? UInt32.max
        var learned: [DNSLearned] = []
        for record in answers where record.name == chain.end && record.type == question.type {
            guard case .address(let address) = record.value else { continue }
            learned.append(DNSLearned(name: question.name, address: address, ttl: min(ttl, record.ttl)))
        }
        return learned
    }

    /// The CNAME records on the chain from the question's name, in order, from a response
    /// `learned` reads, with or without addresses at the end. The resolver keeps each for its own
    /// TTL and then asks only for the rest of the chain, so an answer to that later question names
    /// the chain's end and not the name an app asked for (DNSNameTable follows these back).
    public var aliases: [DNSAlias] { chain?.links ?? [] }

    /// The CNAME chain from the question's name and the name it ends at, from a successful,
    /// untruncated response to an A or AAAA question of class IN. nil when there is nothing to
    /// learn: another kind of message, two CNAMEs for one name, a loop, or too long a chain.
    private var chain: (links: [DNSAlias], end: String)? {
        guard isResponse, opcode == 0, !truncated, responseCode == 0, question.recordClass == dnsClassIN,
              question.type == DNSRecordType.a || question.type == DNSRecordType.aaaa else { return nil }
        var aliases: [String: (target: String, ttl: UInt32)] = [:]
        for record in answers {
            guard case .alias(let target) = record.value, let owner = record.name else { continue }
            // Two CNAMEs for one name are not valid DNS; nothing is learned from such an answer.
            guard aliases[owner] == nil else { return nil }
            aliases[owner] = (target, record.ttl)
        }
        var current = question.name
        var links: [DNSAlias] = []
        var seen: Set<String> = [current]
        while let alias = aliases[current] {
            guard seen.insert(alias.target).inserted, seen.count <= Self.maximumAliases + 1 else { return nil }
            links.append(DNSAlias(name: current, target: alias.target, ttl: alias.ttl))
            current = alias.target
        }
        return (links, current)
    }

    /// Reads the name at `start`: the name, normalized, or nil when it is well formed but not a
    /// host name (a label with other bytes, the root, a numeric last label), and the offset just
    /// past the name where it sits. nil when the name runs past the message, is longer than 255
    /// bytes, uses an unknown label type, or a compression pointer does not point backwards or
    /// takes more than `maximumJumps` jumps. Every step either moves forward over a label or
    /// jumps, so it always ends.
    static func readName(_ bytes: [UInt8], at start: Int) -> (name: String?, end: Int)? {
        var position = start
        var end: Int?
        var labels: [String] = []
        var hostName = true
        var wireLength = 1 // the root label
        var jumps = 0
        while true {
            guard position < bytes.count else { return nil }
            let length = Int(bytes[position])
            switch length & 0xC0 {
            case 0x00:
                if length == 0 {
                    let name = hostName && !labels.isEmpty ? normalizeHost(labels.joined(separator: ".")) : nil
                    return (name, end ?? position + 1)
                }
                let next = position + 1 + length
                wireLength += 1 + length
                guard next <= bytes.count, wireLength <= 255 else { return nil }
                let label = bytes[(position + 1)..<next]
                if hostName, label.allSatisfy(isHostNameByte) {
                    labels.append(String(decoding: label, as: UTF8.self))
                } else {
                    hostName = false
                }
                position = next
            case 0xC0:
                guard position + 1 < bytes.count else { return nil }
                let target = (length & 0x3F) << 8 | Int(bytes[position + 1])
                guard target < position, jumps < maximumJumps else { return nil }
                jumps += 1
                if end == nil { end = position + 2 }
                position = target
            default:
                return nil // 0x40 and 0x80 are extended label types, which nothing uses
            }
        }
    }

    private static func isHostNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 45, 95: return true
        default: return false
        }
    }
}

/// One DNS flow of the system resolver, both directions. It remembers the questions sent and
/// learns only from a response that answers one of them, with the same ID and question, the
/// check the resolver itself applies; a forged response has to pass it too. UDP carries one
/// message per datagram; TCP carries a stream of messages, each after a 2-byte length.
///
/// Offsets are the ones NetworkExtension passes, counted from the start of each direction's
/// data. A UDP datagram that overlaps one already seen is skipped. A TCP stream with a gap or an
/// overlap, or a message of length 0, stops the reader for good (`stopped`), and the caller then
/// lets the flow go unread.
public struct DNSFlowReader: Sendable {
    public static let maximumQueries = 32

    public let stream: Bool
    public private(set) var stopped = false
    private var queries: [QueryKey] = []
    private var next = (outbound: 0, inbound: 0)
    private var buffer = (outbound: [UInt8](), inbound: [UInt8]())

    private struct QueryKey: Equatable, Sendable {
        let id: UInt16
        let question: DNSQuestion
    }

    public init(stream: Bool) {
        self.stream = stream
    }

    /// Whether a query it remembers has had no response yet.
    public var waiting: Bool { !queries.isEmpty }

    /// Bytes the resolver sent: queries are remembered, at most `maximumQueries`, oldest out.
    public mutating func outbound(_ data: Data, offset: Int) {
        for message in messages(data, offset: offset, outbound: true) where !message.isResponse && message.opcode == 0 {
            let key = QueryKey(id: message.id, question: message.question)
            guard !queries.contains(key) else { continue }
            if queries.count >= Self.maximumQueries { queries.removeFirst() }
            queries.append(key)
        }
    }

    /// Bytes the resolver received: what the responses to remembered queries teach. Each query
    /// is answered once.
    public mutating func inbound(_ data: Data, offset: Int) -> [DNSLearned] {
        lessons(data, offset: offset).learned
    }

    /// `inbound`, with the CNAME chains of the same responses.
    public mutating func lessons(_ data: Data, offset: Int) -> (learned: [DNSLearned], aliases: [DNSAlias]) {
        var learned: [DNSLearned] = []
        var aliases: [DNSAlias] = []
        for message in messages(data, offset: offset, outbound: false) where message.isResponse {
            guard let index = queries.firstIndex(of: QueryKey(id: message.id, question: message.question)) else { continue }
            queries.remove(at: index)
            learned += message.learned
            aliases += message.aliases
        }
        return (learned, aliases)
    }

    private mutating func messages(_ data: Data, offset: Int, outbound: Bool) -> [DNSMessage] {
        guard !stopped else { return [] }
        let expected = outbound ? next.outbound : next.inbound
        guard stream else {
            // Datagrams stand alone: a gap loses nothing, an overlap is a repeat.
            guard offset >= expected else { return [] }
            let end = offset + data.count
            if outbound { next.outbound = end } else { next.inbound = end }
            return DNSMessage(data).map { [$0] } ?? []
        }
        guard offset == expected else {
            stop()
            return []
        }
        var pending = outbound ? buffer.outbound : buffer.inbound
        pending.append(contentsOf: data)
        var found: [DNSMessage] = []
        var start = 0
        while pending.count - start >= 2 {
            let length = Int(pending[start]) << 8 | Int(pending[start + 1])
            guard length > 0 else {
                stop()
                return found
            }
            guard pending.count - start >= 2 + length else { break }
            if let message = DNSMessage(Data(pending[(start + 2)..<(start + 2 + length)])) { found.append(message) }
            start += 2 + length
        }
        pending.removeFirst(start)
        if outbound {
            next.outbound += data.count
            buffer.outbound = pending
        } else {
            next.inbound += data.count
            buffer.inbound = pending
        }
        return found
    }

    private mutating func stop() {
        stopped = true
        queries.removeAll()
        buffer = ([], [])
    }
}

/// The system resolver's DNS flows the extension reads, by flow ID, each with its reader.
///
/// Bounded: at most `limit` flows are read at once. A new flow that comes to a full table takes the
/// place of the one quiet the longest, which is let go, so the newest answers are the ones read:
/// a burst of lookups, or the queries nothing answered while the network was away, never keeps
/// the answers after it from being read. On 10 November 2026 the table took 256 flows, counted
/// each for two more minutes once it was let go, and left a new flow unread when full. The 267
/// resolver flows of the two minutes around a network coming back (156 of them in one second)
/// left the answers of the next two minutes unread, and so did a test's 611 flows in half a
/// minute; blackice then looked the host up itself, and for outlook.office365.com that lookup
/// got other addresses than the app had (`address_mismatch`).
///
/// A flow is let go when its reader stops, when the caller says so (`letGo`), when it makes room,
/// or after `idleSeconds` without data, when `expire` hands it back so the caller can tell
/// NetworkExtension to stop filtering it. A flow let go is remembered for another `idleSeconds`,
/// at most `rememberedLimit` of them (when full, the one let go first is forgotten), so data still
/// on its way to a callback is known and passes (`stop`) instead of reaching the caller as a flow
/// it never saw. `Flow` is the extension's flow object, and a test's stand-in.
public struct DNSFlowTable<ID: Hashable, Flow> {
    public static var idleSeconds: TimeInterval { 120 }

    /// Flows read at once, at least 1.
    public let limit: Int
    /// Flows let go that are still remembered, at least 1.
    public let rememberedLimit: Int
    private var reading: [ID: Entry] = [:]
    /// The flows let go, each with when.
    private var released: [ID: TimeInterval] = [:]
    /// Flows let go to make room while a query of theirs had no answer yet, since `takeUnread`.
    private var unread = 0

    private struct Entry {
        let flow: Flow
        var reader: DNSFlowReader
        var lastSeen: TimeInterval
    }

    public enum DataResult: Equatable {
        /// Not a DNS flow being read.
        case unknown
        /// Pass the bytes and keep reading.
        case pass([DNSLearned], aliases: [DNSAlias] = [])
        /// Pass the bytes and stop filtering the flow.
        case stop([DNSLearned], aliases: [DNSAlias] = [])
    }

    public init(limit: Int = 512, rememberedLimit: Int = 4096) {
        self.limit = max(limit, 1)
        self.rememberedLimit = max(rememberedLimit, 1)
    }

    /// The flows being read.
    public var count: Int { reading.count }
    /// The flows let go and not yet forgotten.
    public var rememberedCount: Int { released.count }

    /// Starts reading a flow. When `limit` flows are being read, the one quiet the longest is let
    /// go to make room and returned, so the caller can tell NetworkExtension to stop filtering it.
    public mutating func add(_ id: ID, flow: Flow, stream: Bool, now: TimeInterval) -> Flow? {
        released.removeValue(forKey: id)
        var evicted: Flow?
        if reading[id] == nil, reading.count >= limit,
           let quiet = reading.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            if quiet.value.reader.waiting { unread += 1 }
            evicted = quiet.value.flow
            release(quiet.key, now: now)
        }
        reading[id] = Entry(flow: flow, reader: DNSFlowReader(stream: stream), lastSeen: now)
        return evicted
    }

    public mutating func data(_ id: ID, _ bytes: Data, offset: Int, outbound: Bool, now: TimeInterval) -> DataResult {
        guard var entry = reading[id] else { return released[id] != nil ? .stop([]) : .unknown }
        var lessons: (learned: [DNSLearned], aliases: [DNSAlias]) = ([], [])
        if outbound { entry.reader.outbound(bytes, offset: offset) } else { lessons = entry.reader.lessons(bytes, offset: offset) }
        guard !entry.reader.stopped else {
            release(id, now: now)
            return .stop(lessons.learned, aliases: lessons.aliases)
        }
        entry.lastSeen = now
        reading[id] = entry
        return .pass(lessons.learned, aliases: lessons.aliases)
    }

    /// Stops reading a flow; its later data passes. True when it is one of these.
    @discardableResult
    public mutating func letGo(_ id: ID, now: TimeInterval) -> Bool {
        guard reading[id] != nil else { return released[id] != nil }
        release(id, now: now)
        return true
    }

    /// The flows idle for `idleSeconds`, now let go; forgets the ones let go that long ago.
    public mutating func expire(now: TimeInterval) -> [Flow] {
        released = released.filter { $0.value + Self.idleSeconds > now }
        var idle: [Flow] = []
        for (id, entry) in reading where entry.lastSeen + Self.idleSeconds <= now {
            idle.append(entry.flow)
            release(id, now: now)
        }
        return idle
    }

    /// How many flows were let go to make room before an answer they waited for came, since the
    /// last call: answers nobody read. Then 0.
    public mutating func takeUnread() -> Int {
        defer { unread = 0 }
        return unread
    }

    /// Every flow still being read, all forgotten.
    public mutating func removeAll() -> [Flow] {
        let flows = reading.values.map(\.flow)
        reading.removeAll()
        released.removeAll()
        return flows
    }

    /// From read to let go, remembered from `now`.
    private mutating func release(_ id: ID, now: TimeInterval) {
        reading.removeValue(forKey: id)
        if released[id] == nil, released.count >= rememberedLimit,
           let first = released.min(by: { $0.value < $1.value })?.key {
            released.removeValue(forKey: first)
        }
        released[id] = now
    }
}

/// The names the system resolver's answers gave for each address, as the extension saw them on
/// its DNS flows. Each name lasts as long as the resolver answers from its record (`kept`), for a
/// TTL held between `minimumTTL` and `maximumTTL`. Thread-safe.
///
/// It also keeps the CNAME records of those answers, each as long as the resolver does, for a TTL
/// held between `minimumTTL` and `maximumAliasTTL`, and follows them back from an address's names
/// (`aliases(for:)`). The resolver keeps each record of a chain for its own time and, once the
/// addresses at its end have gone, asks only for the name they belong to. On 10 November 2026
/// outlook.office365.com was three CNAMEs of 300, 300 and 45 s and eight addresses of 15 s under
/// the last name, replaced by eight others at each query: an answer that brought new addresses
/// then named the chain's end or its middle, not the host the app asked for, and blackice's own
/// lookup a moment later got other addresses.
///
/// Bounded: at most `maximumNamesPerAddress` names per address (when full, the name closest to
/// expiring goes) and `maximumAddresses` addresses (when full, expired entries go, then the
/// address whose names all expire soonest); the same numbers bound the aliases of one name and
/// the names with aliases. A name that was never seen, or went, makes no difference to safety:
/// a name listed here is one the address was given for, which is what the host and address check
/// asks, and an alias of it is a name the resolver's own records say resolves to that address.
public final class DNSNameTable: @unchecked Sendable {
    public static let minimumTTL: TimeInterval = 30
    public static let maximumTTL: TimeInterval = 300
    /// A CNAME is kept as long as the resolver keeps it, for a TTL of at most a day.
    public static let maximumAliasTTL: TimeInterval = 86_400
    public static let defaultMaximumAddresses = 4096
    public static let defaultMaximumNamesPerAddress = 16
    /// Aliases followed back from one address's names.
    public static let maximumAliasesFollowed = 64

    public let maximumAddresses: Int
    public let maximumNamesPerAddress: Int
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [IPAddress: [String: TimeInterval]] = [:]
    /// A CNAME's target against the names that are aliases of it, each with when it expires.
    private var aliases: [String: [String: TimeInterval]] = [:]

    /// `clock` returns seconds on a monotonic scale; the default counts sleep (continuousSeconds).
    public init(maximumAddresses: Int = defaultMaximumAddresses,
                maximumNamesPerAddress: Int = defaultMaximumNamesPerAddress,
                clock: @escaping @Sendable () -> TimeInterval = { continuousSeconds() }) {
        self.maximumAddresses = maximumAddresses
        self.maximumNamesPerAddress = maximumNamesPerAddress
        self.clock = clock
    }

    /// Added to the time the resolver keeps a record: the extension reads an answer before the
    /// resolver does, and the two do not count from the same instant.
    public static let slack: TimeInterval = 5

    /// How long the system resolver answers from a record of `ttl` seconds, and `slack`. It
    /// keeps a record for its TTL, a quarter more and 2 s, and for at least 15 s (RRAdjustTTL and
    /// GetEffectiveTTL in mDNSResponder-2881.120.11's DNSCommon), so a name that lasted only its
    /// TTL here went while the resolver still handed its addresses to apps. Asked for one name
    /// twice a second on 10 November 2026 (macOS 27.0.1), it asked the network again 77.0 and
    /// 77.4 s after a CNAME of 60 s, 39.2 s after one of 30 s, 24.2 s after 18 s, 20.1 s after
    /// 15 s, and 15.0 to 15.5 s after addresses of 3 to 9 s. In the half hour before, 10 of the 30
    /// lookups blackice made itself for outlook.office365.com came while the resolver followed a
    /// CNAME of 272 to 298 s that was past its TTL, and so had gone here.
    public static func kept(ttl: TimeInterval) -> TimeInterval {
        max(ttl + (ttl / 4).rounded(.down) + 2, 15) + slack
    }

    public static func lifetime(ttl: UInt32) -> TimeInterval {
        kept(ttl: min(max(TimeInterval(ttl), minimumTTL), maximumTTL))
    }

    public static func aliasLifetime(ttl: UInt32) -> TimeInterval {
        kept(ttl: min(max(TimeInterval(ttl), minimumTTL), maximumAliasTTL))
    }

    public func record(_ learned: [DNSLearned], aliases links: [DNSAlias] = []) {
        guard !learned.isEmpty || !links.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        for link in links {
            let expires = now + Self.aliasLifetime(ttl: link.ttl)
            var names = (aliases[link.target] ?? [:]).filter { $0.value > now }
            if names.isEmpty, aliases[link.target] == nil, aliases.count >= maximumAddresses {
                aliases = aliases.filter { $0.value.values.contains { $0 > now } }
                if aliases.count >= maximumAddresses,
                   let soonest = aliases.min(by: { ($0.value.values.max() ?? 0) < ($1.value.values.max() ?? 0) })?.key {
                    aliases.removeValue(forKey: soonest)
                }
            }
            if names[link.name] == nil, names.count >= maximumNamesPerAddress,
               let soonest = names.min(by: { $0.value < $1.value })?.key {
                names.removeValue(forKey: soonest)
            }
            names[link.name] = max(names[link.name] ?? 0, expires)
            aliases[link.target] = names
        }
        // A link-local answer names no interface, so it says nothing about a flow's address.
        for item in learned where item.address.isCheckable {
            let expires = now + Self.lifetime(ttl: item.ttl)
            var names = (entries[item.address] ?? [:]).filter { $0.value > now }
            if names.isEmpty, entries[item.address] == nil, entries.count >= maximumAddresses {
                makeRoom(now: now)
            }
            if names[item.name] == nil, names.count >= maximumNamesPerAddress,
               let soonest = names.min(by: { $0.value < $1.value })?.key {
                names.removeValue(forKey: soonest)
            }
            names[item.name] = max(names[item.name] ?? 0, expires)
            entries[item.address] = names
        }
    }

    /// The names whose answers gave this address and have not expired. Never blocks for long.
    public func names(for address: IPAddress?) -> Set<String> {
        guard let address, address.isCheckable else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard let names = entries[address] else { return [] }
        let now = clock()
        return Set(names.filter { $0.value > now }.keys)
    }

    /// The names that are aliases, through CNAME records that have not expired, of a name in
    /// `names(for:)`: the resolver's records say each resolves to this address too. At most
    /// `maximumAliasesFollowed`. Never blocks for long.
    public func aliases(for address: IPAddress?) -> Set<String> {
        guard let address, address.isCheckable else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard let names = entries[address] else { return [] }
        let now = clock()
        let direct = Set(names.filter { $0.value > now }.keys)
        var found: Set<String> = []
        var pending = Array(direct)
        while let name = pending.popLast(), found.count < Self.maximumAliasesFollowed {
            for (alias, expires) in aliases[name] ?? [:] where expires > now && !direct.contains(alias) {
                guard found.count < Self.maximumAliasesFollowed else { break }
                if found.insert(alias).inserted { pending.append(alias) }
            }
        }
        return found
    }

    public var addressCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var aliasTargetCount: Int {
        lock.lock(); defer { lock.unlock() }
        return aliases.count
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        aliases.removeAll()
    }

    /// Under the lock.
    private func makeRoom(now: TimeInterval) {
        entries = entries.filter { $0.value.values.contains { $0 > now } }
        guard entries.count >= maximumAddresses,
              let soonest = entries.min(by: { ($0.value.values.max() ?? 0) < ($1.value.values.max() ?? 0) })?.key else { return }
        entries.removeValue(forKey: soonest)
    }
}
