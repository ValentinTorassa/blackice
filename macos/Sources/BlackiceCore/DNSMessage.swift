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
        guard isResponse, opcode == 0, !truncated, responseCode == 0, question.recordClass == dnsClassIN,
              question.type == DNSRecordType.a || question.type == DNSRecordType.aaaa else { return [] }
        var aliases: [String: (target: String, ttl: UInt32)] = [:]
        for record in answers {
            guard case .alias(let target) = record.value, let owner = record.name else { continue }
            // Two CNAMEs for one name are not valid DNS; nothing is learned from such an answer.
            guard aliases[owner] == nil else { return [] }
            aliases[owner] = (target, record.ttl)
        }
        var current = question.name
        var ttl = UInt32.max
        var seen: Set<String> = [current]
        while let alias = aliases[current] {
            guard seen.insert(alias.target).inserted, seen.count <= Self.maximumAliases + 1 else { return [] }
            ttl = min(ttl, alias.ttl)
            current = alias.target
        }
        var learned: [DNSLearned] = []
        for record in answers where record.name == current && record.type == question.type {
            guard case .address(let address) = record.value else { continue }
            learned.append(DNSLearned(name: question.name, address: address, ttl: min(ttl, record.ttl)))
        }
        return learned
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
        var learned: [DNSLearned] = []
        for message in messages(data, offset: offset, outbound: false) where message.isResponse {
            guard let index = queries.firstIndex(of: QueryKey(id: message.id, question: message.question)) else { continue }
            queries.remove(at: index)
            learned += message.learned
        }
        return learned
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
/// Bounded: when full, a new flow is not read and passes all the same. A flow is let go when its
/// reader stops, when the caller says so (`letGo`), or after `idleSeconds` without data, when
/// `expire` hands it back so the caller can tell NetworkExtension to stop filtering it. A flow
/// let go is remembered for another `idleSeconds`, so data still on its way to a callback is
/// known and passes (`stop`) instead of reaching the caller as a flow it never saw. `Flow` is
/// the extension's flow object, and a test's stand-in.
public struct DNSFlowTable<ID: Hashable, Flow> {
    public static var idleSeconds: TimeInterval { 120 }

    public let limit: Int
    private var entries: [ID: Entry] = [:]

    private struct Entry {
        let flow: Flow
        /// nil once let go.
        var reader: DNSFlowReader?
        var lastSeen: TimeInterval
    }

    public enum DataResult: Equatable {
        /// Not a DNS flow being read.
        case unknown
        /// Pass the bytes and keep reading.
        case pass([DNSLearned])
        /// Pass the bytes and stop filtering the flow.
        case stop([DNSLearned])
    }

    public init(limit: Int = 256) { self.limit = limit }

    public var count: Int { entries.count }

    /// False when the table is full: let the flow pass unread.
    public mutating func add(_ id: ID, flow: Flow, stream: Bool, now: TimeInterval) -> Bool {
        guard entries[id] != nil || entries.count < limit else { return false }
        entries[id] = Entry(flow: flow, reader: DNSFlowReader(stream: stream), lastSeen: now)
        return true
    }

    public mutating func data(_ id: ID, _ bytes: Data, offset: Int, outbound: Bool, now: TimeInterval) -> DataResult {
        guard var entry = entries[id] else { return .unknown }
        guard var reader = entry.reader else { return .stop([]) }
        var learned: [DNSLearned] = []
        if outbound { reader.outbound(bytes, offset: offset) } else { learned = reader.inbound(bytes, offset: offset) }
        entry.reader = reader.stopped ? nil : reader
        entry.lastSeen = now
        entries[id] = entry
        return reader.stopped ? .stop(learned) : .pass(learned)
    }

    /// Stops reading a flow; its later data passes. True when it is one of these.
    @discardableResult
    public mutating func letGo(_ id: ID, now: TimeInterval) -> Bool {
        guard let entry = entries[id] else { return false }
        if entry.reader != nil { entries[id] = Entry(flow: entry.flow, reader: nil, lastSeen: now) }
        return true
    }

    /// The flows idle for `idleSeconds`, now let go; forgets the ones let go that long ago.
    public mutating func expire(now: TimeInterval) -> [Flow] {
        var released: [Flow] = []
        for (id, entry) in entries where entry.lastSeen + Self.idleSeconds <= now {
            if entry.reader == nil {
                entries.removeValue(forKey: id)
            } else {
                entries[id] = Entry(flow: entry.flow, reader: nil, lastSeen: now)
                released.append(entry.flow)
            }
        }
        return released
    }

    /// Every flow still being read, all forgotten.
    public mutating func removeAll() -> [Flow] {
        let reading = entries.values.filter { $0.reader != nil }.map(\.flow)
        entries.removeAll()
        return reading
    }
}

/// The names the system resolver's answers gave for each address, as the extension saw them on
/// its DNS flows. Each name lasts for its record's TTL, held between `minimumTTL` and
/// `maximumTTL`. Thread-safe.
///
/// Bounded: at most `maximumNamesPerAddress` names per address (when full, the name closest to
/// expiring goes) and `maximumAddresses` addresses (when full, expired entries go, then the
/// address whose names all expire soonest). A name that was never seen, or went, makes no
/// difference to safety: a name listed here is one the address was given for, which is what
/// the host and address check asks.
public final class DNSNameTable: @unchecked Sendable {
    public static let minimumTTL: TimeInterval = 30
    public static let maximumTTL: TimeInterval = 300
    public static let defaultMaximumAddresses = 4096
    public static let defaultMaximumNamesPerAddress = 16

    public let maximumAddresses: Int
    public let maximumNamesPerAddress: Int
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [IPAddress: [String: TimeInterval]] = [:]

    /// `clock` returns seconds on a monotonic scale; the default counts sleep (continuousSeconds).
    public init(maximumAddresses: Int = defaultMaximumAddresses,
                maximumNamesPerAddress: Int = defaultMaximumNamesPerAddress,
                clock: @escaping @Sendable () -> TimeInterval = { continuousSeconds() }) {
        self.maximumAddresses = maximumAddresses
        self.maximumNamesPerAddress = maximumNamesPerAddress
        self.clock = clock
    }

    public static func lifetime(ttl: UInt32) -> TimeInterval {
        min(max(TimeInterval(ttl), minimumTTL), maximumTTL)
    }

    public func record(_ learned: [DNSLearned]) {
        guard !learned.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
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

    public var addressCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    /// Under the lock.
    private func makeRoom(now: TimeInterval) {
        entries = entries.filter { $0.value.values.contains { $0 > now } }
        guard entries.count >= maximumAddresses,
              let soonest = entries.min(by: { ($0.value.values.max() ?? 0) < ($1.value.values.max() ?? 0) })?.key else { return }
        entries.removeValue(forKey: soonest)
    }
}
