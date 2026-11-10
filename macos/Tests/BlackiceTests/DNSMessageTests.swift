import Foundation
import Testing
@testable import BlackiceCore

// The DNS parser, the per-flow reader, the flow table and the name table, with messages built
// byte by byte.

/// Writes DNS messages, keeping offsets so later names can point back at earlier ones.
private struct Wire {
    var bytes: [UInt8] = []

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }

    mutating func u16(_ value: Int) { bytes += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    mutating func u32(_ value: UInt32) {
        bytes += [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// The labels and the root label. Returns where the name starts.
    @discardableResult
    mutating func name(_ text: String) -> Int {
        let start = count
        for label in text.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes.append(0)
        return start
    }

    mutating func pointer(_ offset: Int) { bytes += [0xC0 | UInt8(offset >> 8), UInt8(offset & 0xFF)] }

    mutating func header(id: Int = 0x1234, flags: Int = 0x8180, questions: Int = 1, answers: Int, additional: Int = 0) {
        u16(id); u16(flags); u16(questions); u16(answers); u16(0); u16(additional)
    }

    /// Right after the header, so the question's name is at `questionName`.
    mutating func question(_ name: String, type: UInt16 = DNSRecordType.a, recordClass: Int = 1) {
        self.name(name)
        u16(Int(type)); u16(recordClass)
    }

    /// The rest of a record whose owner name was just written.
    mutating func record(type: UInt16, ttl: UInt32 = 300, recordClass: Int = 1, data: [UInt8]) {
        u16(Int(type)); u16(recordClass); u32(ttl); u16(data.count)
        bytes += data
    }
}

private let questionName = 12

private func ip(_ text: String) -> IPAddress { IPAddress(text)! }

private func learned(_ name: String, _ address: String, _ ttl: UInt32) -> DNSLearned {
    DNSLearned(name: name, address: ip(address), ttl: ttl)
}

/// A response whose answers are address records owned by the question's name (by pointer).
private func response(_ name: String, type: UInt16 = DNSRecordType.a, id: Int = 0x1234, flags: Int = 0x8180,
                      addresses: [(String, UInt32)]) -> Data {
    var wire = Wire()
    wire.header(id: id, flags: flags, answers: addresses.count)
    wire.question(name, type: type)
    for (address, ttl) in addresses {
        wire.pointer(questionName)
        wire.record(type: ip(address).bytes.count == 4 ? DNSRecordType.a : DNSRecordType.aaaa, ttl: ttl, data: ip(address).bytes)
    }
    return wire.data
}

private func alias(_ name: String, _ target: String, _ ttl: UInt32) -> DNSAlias {
    DNSAlias(name: name, target: target, ttl: ttl)
}

/// A response whose answers are a CNAME chain from the question's name, each with its TTL, and
/// address records owned by the chain's last name. Names are written out, with no pointers.
private func chainResponse(_ name: String, type: UInt16 = DNSRecordType.a, id: Int = 0x1234,
                           chain: [(String, UInt32)], addresses: [(String, UInt32)] = []) -> Data {
    var wire = Wire()
    wire.header(id: id, answers: chain.count + addresses.count)
    wire.question(name, type: type)
    var owner = name
    for (target, ttl) in chain {
        wire.name(owner)
        var data = Wire()
        data.name(target)
        wire.record(type: DNSRecordType.cname, ttl: ttl, data: data.bytes)
        owner = target
    }
    for (address, ttl) in addresses {
        wire.name(owner)
        wire.record(type: ip(address).bytes.count == 4 ? DNSRecordType.a : DNSRecordType.aaaa, ttl: ttl, data: ip(address).bytes)
    }
    return wire.data
}

private func query(_ name: String, type: UInt16 = DNSRecordType.a, id: Int = 0x1234) -> Data {
    var wire = Wire()
    wire.header(id: id, flags: 0x0100, answers: 0)
    wire.question(name, type: type)
    return wire.data
}

/// TCP framing: a 2-byte length, then the message.
private func framed(_ message: Data) -> Data {
    Data([UInt8(message.count >> 8), UInt8(message.count & 0xFF)]) + message
}

/// SplitMix64: the same bytes on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// www.example.com -> edge.cdn.example.net -> e1.cdn.example.net, then two A records for e1,
/// with the CNAME chain written partly with compression pointers.
private func cnameResponse() -> Data {
    var wire = Wire()
    wire.header(answers: 4)
    wire.question("www.example.com")
    wire.pointer(questionName)
    // The target's name is in the record data; the next records point back at it.
    var target = Wire()
    target.name("edge.cdn.example.net")
    let edge = wire.count + 10
    wire.record(type: DNSRecordType.cname, ttl: 300, data: target.bytes)
    wire.pointer(edge)
    // "e1" plus a pointer to "cdn.example.net" inside the first target.
    let cdn = edge + 5
    var e1Data = Wire()
    e1Data.bytes = [2] + Array("e1".utf8)
    e1Data.pointer(cdn)
    let e1 = wire.count + 10
    wire.record(type: DNSRecordType.cname, ttl: 20, data: e1Data.bytes)
    wire.pointer(e1)
    wire.record(type: DNSRecordType.a, ttl: 60, data: ip("203.0.113.9").bytes)
    wire.pointer(e1)
    wire.record(type: DNSRecordType.a, ttl: 10, data: ip("203.0.113.10").bytes)
    return wire.data
}

struct DNSMessageTests {
    @Test func aResponseTeachesTheQuestionsNameForEachAddress() throws {
        let message = try #require(DNSMessage(response("API.GitHub.com", addresses: [("140.82.121.6", 60), ("140.82.121.5", 30)])))
        #expect(message.id == 0x1234 && message.isResponse && message.opcode == 0 && !message.truncated)
        #expect(message.question == DNSQuestion(name: "api.github.com", type: DNSRecordType.a))
        #expect(message.answers.count == 2)
        #expect(message.learned == [learned("api.github.com", "140.82.121.6", 60), learned("api.github.com", "140.82.121.5", 30)])

        let v6 = try #require(DNSMessage(response("example.org", type: DNSRecordType.aaaa, addresses: [("2001:db8::7", 120)])))
        #expect(v6.learned == [learned("example.org", "2001:db8::7", 120)])
    }

    @Test func aCNAMEChainTeachesTheQuestionsNameNotTheTarget() throws {
        let message = try #require(DNSMessage(cnameResponse()))
        #expect(message.answers.map(\.name) == ["www.example.com", "edge.cdn.example.net", "e1.cdn.example.net", "e1.cdn.example.net"])
        #expect(message.answers[1].value == .alias("e1.cdn.example.net"))
        // The smallest TTL along the chain and the address record.
        #expect(message.learned == [learned("www.example.com", "203.0.113.9", 20), learned("www.example.com", "203.0.113.10", 10)])
        // Each CNAME on the chain, with its own TTL.
        #expect(message.aliases == [alias("www.example.com", "edge.cdn.example.net", 300),
                                    alias("edge.cdn.example.net", "e1.cdn.example.net", 20)])
    }

    @Test func theChainIsReadWithOrWithoutAddressesAndOnlyFromTheQuestionsName() throws {
        // An AAAA question whose chain ends at a name with no AAAA record: the CNAMEs still hold.
        let none = try #require(DNSMessage(chainResponse("mail.example.com", type: DNSRecordType.aaaa,
                                                         chain: [("mail.cdn.example.net", 300), ("pool.cdn.example.net", 45)])))
        #expect(none.learned.isEmpty)
        #expect(none.aliases == [alias("mail.example.com", "mail.cdn.example.net", 300),
                                 alias("mail.cdn.example.net", "pool.cdn.example.net", 45)])
        // No CNAME: no alias.
        let plain = try #require(DNSMessage(response("example.org", addresses: [("203.0.113.9", 60)])))
        #expect(plain.aliases.isEmpty)
        // A CNAME for a name off the chain, as a hostile server might add, teaches nothing.
        var wire = Wire()
        wire.header(answers: 2)
        wire.question("evil.example.net")
        wire.pointer(questionName)
        wire.record(type: DNSRecordType.a, data: ip("203.0.113.66").bytes)
        wire.name("pypi.org")
        var target = Wire()
        target.name("evil.example.net")
        wire.record(type: DNSRecordType.cname, data: target.bytes)
        let hostile = try #require(DNSMessage(wire.data))
        #expect(hostile.learned == [learned("evil.example.net", "203.0.113.66", 300)] && hostile.aliases.isEmpty)
        // A failed response, a loop and two CNAMEs for one name teach none either.
        var failed = [UInt8](chainResponse("mail.example.com", chain: [("mail.cdn.example.net", 300)]))
        failed[3] = 0x83
        #expect(try #require(DNSMessage(Data(failed))).aliases.isEmpty)
        let loop = try #require(DNSMessage(chainResponse("a.example.com", chain: [("b.example.com", 60), ("a.example.com", 60)])))
        #expect(loop.aliases.isEmpty && loop.learned.isEmpty)
        var twice = Wire()
        twice.header(answers: 2)
        twice.question("a.example.com")
        for name in ["b.example.com", "c.example.com"] {
            twice.pointer(questionName)
            var data = Wire()
            data.name(name)
            twice.record(type: DNSRecordType.cname, data: data.bytes)
        }
        #expect(try #require(DNSMessage(twice.data)).aliases.isEmpty)
    }

    @Test func recordsOffTheChainTeachNothing() throws {
        var wire = Wire()
        wire.header(answers: 4)
        wire.question("evil.example.net")
        wire.pointer(questionName)
        wire.record(type: DNSRecordType.a, data: ip("203.0.113.66").bytes)
        // A record for a name nobody asked about, as a hostile server might add.
        wire.name("pypi.org")
        wire.record(type: DNSRecordType.a, data: ip("203.0.113.67").bytes)
        // An AAAA answer to an A question.
        wire.pointer(questionName)
        wire.record(type: DNSRecordType.aaaa, data: ip("2001:db8::66").bytes)
        // An owner that is not a host name.
        wire.bytes += [4] + Array("a b!".utf8) + [0]
        wire.record(type: DNSRecordType.a, data: ip("203.0.113.68").bytes)
        let message = try #require(DNSMessage(wire.data))
        #expect(message.answers[3].name == nil)
        #expect(message.learned == [learned("evil.example.net", "203.0.113.66", 300)])

        // An address at the start of a chain, not at its end, is not the name's.
        var chain = Wire()
        chain.header(answers: 3)
        chain.question("www.example.com")
        chain.pointer(questionName)
        chain.record(type: DNSRecordType.a, data: ip("203.0.113.70").bytes)
        chain.pointer(questionName)
        var target = Wire()
        target.name("cdn.example.net")
        let cdn = chain.count + 10
        chain.record(type: DNSRecordType.cname, data: target.bytes)
        chain.pointer(cdn)
        chain.record(type: DNSRecordType.a, data: ip("203.0.113.71").bytes)
        #expect(DNSMessage(chain.data)?.learned == [learned("www.example.com", "203.0.113.71", 300)])
    }

    @Test func onlySuccessfulCompleteAnswersToAddressQuestionsTeach() throws {
        let answers = [("203.0.113.9", UInt32(60))]
        // Truncated (TC), NXDOMAIN, an opcode other than QUERY, and a query.
        for flags in [0x8380, 0x8183, 0x8980, 0x0100] {
            let message = try #require(DNSMessage(response("example.org", flags: flags, addresses: answers)))
            #expect(message.learned.isEmpty, "flags \(flags)")
        }
        #expect(DNSMessage(response("example.org", flags: 0x0100, addresses: answers))?.answers.isEmpty == true)
        // A question for another type, or another class.
        #expect(DNSMessage(response("example.org", type: 15, addresses: answers))?.learned.isEmpty == true)
        var chaos = Wire()
        chaos.header(answers: 1)
        chaos.question("example.org", recordClass: 3)
        chaos.pointer(questionName)
        chaos.record(type: DNSRecordType.a, recordClass: 3, data: ip("203.0.113.9").bytes)
        let message = try #require(DNSMessage(chaos.data))
        #expect(message.answers[0].value == .other && message.learned.isEmpty)
    }

    @Test func exactlyOneQuestion() {
        for questions in [0, 2] {
            var wire = Wire()
            wire.header(questions: questions, answers: 0)
            wire.question("example.org")
            wire.question("example.net")
            #expect(DNSMessage(wire.data) == nil)
        }
        // The question must be a host name.
        for raw: [UInt8] in [[0], [3] + Array("a b".utf8) + [0], [3] + Array("a.b".utf8) + [0],
                             [3] + Array("1-2".utf8) + [1] + Array("3".utf8) + [0]] {
            var wire = Wire()
            wire.header(answers: 0)
            wire.bytes += raw
            wire.u16(1); wire.u16(1)
            #expect(DNSMessage(wire.data) == nil, "\(raw)")
        }
    }

    @Test func compressionPointersGoBackwardsAndAreBounded() {
        func message(owner: (inout Wire) -> Void) -> Data {
            var wire = Wire()
            wire.header(answers: 1)
            wire.question("example.org")
            owner(&wire)
            wire.record(type: DNSRecordType.a, data: ip("203.0.113.9").bytes)
            return wire.data
        }
        // Itself, forwards, and a label followed by a pointer back to that label.
        #expect(DNSMessage(message { $0.pointer($0.count) }) == nil)
        #expect(DNSMessage(message { $0.pointer($0.count + 2) }) == nil)
        #expect(DNSMessage(message { wire in
            let start = wire.count
            wire.bytes += [1, UInt8(ascii: "a")]
            wire.pointer(start)
        }) == nil)
        // Past the end of the message.
        #expect(DNSMessage(message { $0.pointer(0x3FFF) }) == nil)

        // A chain of pointers, each to the one before: 16 jumps in all are read, 17 are not.
        func chained(_ links: Int) -> Data {
            var wire = Wire()
            wire.header(answers: 2)
            wire.question("example.org")
            wire.pointer(questionName)
            var chain = Wire()
            let first = wire.count + 10
            chain.pointer(questionName)
            for index in 1..<links { chain.pointer(first + 2 * (index - 1)) }
            wire.record(type: 99, data: chain.bytes)
            wire.pointer(first + 2 * (links - 1))
            wire.record(type: DNSRecordType.a, data: ip("203.0.113.9").bytes)
            return wire.data
        }
        #expect(DNSMessage(chained(15))?.learned == [learned("example.org", "203.0.113.9", 300)])
        #expect(DNSMessage(chained(16)) == nil)
    }

    @Test func everyTruncationIsRefused() {
        for whole in [cnameResponse(), response("example.org", addresses: [("203.0.113.9", 60)]), query("example.org")] {
            #expect(DNSMessage(whole) != nil)
            for length in 0..<whole.count {
                #expect(DNSMessage(whole.prefix(length)) == nil, "\(length) of \(whole.count)")
            }
        }
    }

    @Test func malformedRecordsAndLimits() {
        func one(_ type: UInt16, _ data: [UInt8]) -> Data {
            var wire = Wire()
            wire.header(answers: 1)
            wire.question("example.org")
            wire.pointer(questionName)
            wire.record(type: type, data: data)
            return wire.data
        }
        #expect(DNSMessage(one(DNSRecordType.a, [203, 0, 113, 9, 0])) == nil)
        #expect(DNSMessage(one(DNSRecordType.aaaa, ip("203.0.113.9").bytes)) == nil)
        var name = Wire()
        name.name("cdn.example.net")
        #expect(DNSMessage(one(DNSRecordType.cname, name.bytes + [0])) == nil)
        #expect(DNSMessage(one(DNSRecordType.cname, Array(name.bytes.dropLast()))) == nil)
        // Unknown types are skipped whatever their data.
        #expect(DNSMessage(one(99, [1, 2, 3]))?.answers.first?.value == .other)

        // Label types 0x40 and 0x80, and a name over 255 bytes.
        let long = String(repeating: "a", count: 63)
        #expect(DNSMessage(query(String(repeating: "a", count: 64) + ".org")) == nil)
        var extended = Wire()
        extended.header(answers: 0)
        extended.bytes += [0x80, 0]
        extended.u16(1); extended.u16(1)
        #expect(DNSMessage(extended.data) == nil)
        #expect(DNSMessage(query([long, long, long, long, "org"].joined(separator: "."))) == nil)
        #expect(DNSMessage(query([long, long, long, String(repeating: "a", count: 57), "org"].joined(separator: "."))) != nil)

        // Too many answers, and too many bytes.
        var many = Wire()
        many.header(answers: DNSMessage.maximumAnswers + 1)
        many.question("example.org")
        #expect(DNSMessage(many.data) == nil)
        var huge = response("example.org", addresses: [("203.0.113.9", 60)])
        huge.append(Data(count: DNSMessage.maximumBytes - huge.count))
        #expect(DNSMessage(huge) != nil)
        huge.append(0)
        #expect(DNSMessage(huge) == nil)
    }

    @Test func ttlWithTheTopBitReadsAsZero() {
        #expect(DNSMessage(response("example.org", addresses: [("203.0.113.9", 0x8000_0001)]))?.learned
            == [learned("example.org", "203.0.113.9", 0)])
    }

    @Test func ambiguousLoopingOrLongAliasChainsTeachNothing() {
        func chain(_ aliases: [(String, String)], addressOwner: String) -> Data {
            var wire = Wire()
            wire.header(answers: aliases.count + 1)
            wire.question("www.example.com")
            for (owner, target) in aliases {
                wire.name(owner)
                var data = Wire()
                data.name(target)
                wire.record(type: DNSRecordType.cname, data: data.bytes)
            }
            wire.name(addressOwner)
            wire.record(type: DNSRecordType.a, data: ip("203.0.113.9").bytes)
            return wire.data
        }
        // Two CNAMEs for one name: whichever came last must not win.
        for owner in ["a.example.net", "b.example.net"] {
            #expect(DNSMessage(chain([("www.example.com", "a.example.net"), ("www.example.com", "b.example.net")],
                                     addressOwner: owner))?.learned.isEmpty == true)
        }
        #expect(DNSMessage(chain([("www.example.com", "a.example.net"), ("a.example.net", "www.example.com")],
                                 addressOwner: "www.example.com"))?.learned.isEmpty == true)
        let names = ["www.example.com"] + (1...17).map { "a\($0).example.net" }
        let sixteen = (0..<16).map { (names[$0], names[$0 + 1]) }
        #expect(DNSMessage(chain(sixteen, addressOwner: names[16]))?.learned == [learned("www.example.com", "203.0.113.9", 300)])
        let seventeen = (0..<17).map { (names[$0], names[$0 + 1]) }
        #expect(DNSMessage(chain(seventeen, addressOwner: names[17]))?.learned.isEmpty == true)
    }

    @Test func otherSectionsAndTrailingBytesAreIgnored() {
        // The address of the CNAME target sits in the additional section, which is not read.
        var wire = Wire()
        wire.header(answers: 1, additional: 1)
        wire.question("www.example.com")
        wire.pointer(questionName)
        var target = Wire()
        target.name("cdn.example.net")
        let cdn = wire.count + 10
        wire.record(type: DNSRecordType.cname, data: target.bytes)
        wire.pointer(cdn)
        wire.record(type: DNSRecordType.a, data: ip("203.0.113.9").bytes)
        #expect(DNSMessage(wire.data)?.learned.isEmpty == true)
        let trailing = response("example.org", addresses: [("203.0.113.9", 60)]) + Data([0xDE, 0xAD])
        #expect(DNSMessage(trailing)?.learned == [learned("example.org", "203.0.113.9", 60)])
    }

    @Test func randomAndMutatedBytesNeverCrash() {
        var random = SeededGenerator(state: 0x0B1A_C41C)
        let valid = [cnameResponse(), response("example.org", addresses: [("203.0.113.9", 60), ("2001:db8::9", 60)])]
        var parsed = 0
        for round in 0..<4000 {
            var bytes: [UInt8]
            switch round % 3 {
            case 0:
                bytes = (0..<Int.random(in: 0...300, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            case 1:
                // A plausible header, then noise.
                bytes = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, UInt8.random(in: 0...6, using: &random), 0, 0, 0, 0]
                bytes += (0..<Int.random(in: 0...200, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            default:
                bytes = [UInt8](valid[round % 2])
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
                }
            }
            guard let message = DNSMessage(Data(bytes)) else { continue }
            parsed += 1
            for item in message.learned { #expect(normalizeHost(item.name) == item.name) }
        }
        #expect(parsed > 0)
    }
}

/// Feeds a reader with offsets that follow on, as NetworkExtension passes them.
private struct Feeder {
    var reader: DNSFlowReader
    var sent = 0
    var received = 0

    init(stream: Bool = false) { reader = DNSFlowReader(stream: stream) }

    mutating func send(_ data: Data) {
        reader.outbound(data, offset: sent)
        sent += data.count
    }

    mutating func receive(_ data: Data) -> [DNSLearned] {
        defer { received += data.count }
        return reader.inbound(data, offset: received)
    }
}

struct DNSFlowReaderTests {
    private let github = [("140.82.121.6", UInt32(60))]

    @Test func learnsOnlyFromAnswersToItsOwnQueries() {
        var feed = Feeder()
        feed.send(query("api.github.com", id: 0x0101))
        // Another ID, another name, another type: nothing.
        #expect(feed.receive(response("api.github.com", id: 0x0202, addresses: github)).isEmpty)
        #expect(feed.receive(response("evil.example.net", id: 0x0101, addresses: github)).isEmpty)
        #expect(feed.receive(response("api.github.com", type: DNSRecordType.aaaa, id: 0x0101, addresses: [("2001:db8::1", 60)])).isEmpty)
        // The answer, once.
        #expect(feed.receive(response("api.github.com", id: 0x0101, addresses: github)) == [learned("api.github.com", "140.82.121.6", 60)])
        #expect(feed.receive(response("api.github.com", id: 0x0101, addresses: github)).isEmpty)
        // Names compare without case; a retransmitted query is remembered once.
        feed.send(query("API.GitHub.COM", id: 7))
        feed.send(query("API.GitHub.COM", id: 7))
        #expect(feed.receive(response("api.github.com", id: 7, addresses: github)).count == 1)
        #expect(feed.receive(response("api.github.com", id: 7, addresses: github)).isEmpty)
        // A response sent outbound is not a query.
        feed.send(response("example.org", id: 9, addresses: github))
        #expect(feed.receive(response("example.org", id: 9, addresses: github)).isEmpty)
        // Garbage passes through without a trace.
        feed.send(Data([1, 2, 3]))
        #expect(feed.receive(Data(repeating: 0xFF, count: 40)).isEmpty)
        #expect(!feed.reader.stopped)
    }

    @Test func remembersALimitedNumberOfQueries() {
        var feed = Feeder()
        for id in 0...DNSFlowReader.maximumQueries { feed.send(query("example.org", id: id)) }
        #expect(feed.receive(response("example.org", id: 0, addresses: github)).isEmpty)
        #expect(feed.receive(response("example.org", id: 1, addresses: github)).count == 1)
        #expect(feed.receive(response("example.org", id: DNSFlowReader.maximumQueries, addresses: github)).count == 1)
    }

    @Test func datagramsStandAloneAndRepeatsAreSkipped() {
        var reader = DNSFlowReader(stream: false)
        let answer = response("example.org", id: 1, addresses: github)
        reader.outbound(query("example.org", id: 1), offset: 0)
        reader.outbound(query("example.org", id: 1), offset: 0)
        #expect(reader.inbound(answer, offset: 0).count == 1)
        // The same bytes again at the same offset are a repeat, even with a query waiting.
        reader.outbound(query("example.org", id: 1), offset: 100)
        #expect(reader.inbound(answer, offset: 0).isEmpty)
        // A gap loses nothing.
        #expect(reader.inbound(answer, offset: 5000).count == 1)
    }

    @Test func tcpMessagesAreReassembled() {
        var feed = Feeder(stream: true)
        // A query split across two sends.
        let first = framed(query("example.org", id: 1))
        feed.send(first.prefix(3))
        feed.send(first.dropFirst(3))
        // The answer in three pieces, the length itself split.
        let answer = framed(response("example.org", id: 1, addresses: github))
        #expect(feed.receive(answer.prefix(1)).isEmpty)
        #expect(feed.receive(answer.dropFirst(1).prefix(10)).isEmpty)
        #expect(feed.receive(answer.dropFirst(11)) == [learned("example.org", "140.82.121.6", 60)])
        // Two queries and two answers in one piece each.
        feed.send(framed(query("a.example.org", id: 2)) + framed(query("b.example.org", id: 3)))
        let both = framed(response("a.example.org", id: 2, addresses: github)) + framed(response("b.example.org", id: 3, addresses: github))
        #expect(feed.receive(both).map(\.name) == ["a.example.org", "b.example.org"])
        #expect(!feed.reader.stopped)
    }

    @Test func aBrokenTCPStreamStopsTheReader() {
        var gap = DNSFlowReader(stream: true)
        gap.outbound(framed(query("example.org", id: 1)), offset: 0)
        #expect(gap.inbound(framed(response("example.org", id: 1, addresses: github)), offset: 4).isEmpty)
        #expect(gap.stopped)
        #expect(gap.inbound(framed(response("example.org", id: 1, addresses: github)), offset: 0).isEmpty)

        var zero = Feeder(stream: true)
        zero.send(framed(query("example.org", id: 1)))
        #expect(zero.receive(Data([0, 0])).isEmpty)
        #expect(zero.reader.stopped)
    }
}

struct DNSFlowTableTests {
    @Test func readsFlowsUntilIdleThenLetsThemGo() {
        var table = DNSFlowTable<Int, String>(limit: 2)
        #expect(table.add(1, flow: "one", stream: false, now: 0) == true)
        #expect(table.add(2, flow: "two", stream: false, now: 0) == true)
        // Full: the third flow passes unread.
        #expect(table.add(3, flow: "three", stream: false, now: 0) == false)
        #expect(table.data(3, Data(), offset: 0, outbound: true, now: 0) == .unknown)

        #expect(table.data(1, query("example.org", id: 5), offset: 0, outbound: true, now: 1) == .pass([]))
        #expect(table.data(1, response("example.org", id: 5, addresses: [("203.0.113.9", 60)]), offset: 0, outbound: false, now: 2)
            == .pass([learned("example.org", "203.0.113.9", 60)]))
        // A response with a CNAME chain gives the chain too. Each datagram starts where the last ended.
        let sent = query("example.org", id: 5).count
        let received = response("example.org", id: 5, addresses: [("203.0.113.9", 60)]).count
        #expect(table.data(1, query("mail.example.com", id: 6), offset: sent, outbound: true, now: 2) == .pass([]))
        #expect(table.data(1, chainResponse("mail.example.com", id: 6, chain: [("pool.cdn.example.net", 45)],
                                            addresses: [("203.0.113.10", 15)]), offset: received, outbound: false, now: 2)
            == .pass([learned("mail.example.com", "203.0.113.10", 15)], aliases: [alias("mail.example.com", "pool.cdn.example.net", 45)]))

        // Two has been idle for two minutes: let go, and its late data passes.
        #expect(table.expire(now: 119).isEmpty)
        #expect(table.expire(now: 120) == ["two"])
        #expect(table.data(2, query("example.org"), offset: 0, outbound: true, now: 121) == .stop([]))
        #expect(table.count == 2)
        // One, idle since 2, is let go; two, let go at 120, is forgotten at 240.
        #expect(table.expire(now: 239) == ["one"])
        #expect(table.expire(now: 240) == [])
        #expect(table.data(2, Data(), offset: 0, outbound: true, now: 241) == .unknown)
        #expect(table.data(1, Data(), offset: 0, outbound: true, now: 241) == .stop([]))
        #expect(table.letGo(1, now: 241) && !table.letGo(2, now: 241))
    }

    @Test func aStoppedOrLetGoFlowPassesUntilForgotten() {
        var table = DNSFlowTable<Int, String>()
        #expect(table.add(1, flow: "tcp", stream: true, now: 0) == true)
        // A gap in the stream stops the reader; data still on its way passes.
        #expect(table.data(1, Data([0, 5, 1]), offset: 7, outbound: false, now: 1) == .stop([]))
        #expect(table.data(1, Data(), offset: 0, outbound: true, now: 2) == .stop([]))
        // The caller lets a flow go when NetworkExtension reports its data complete.
        #expect(table.add(2, flow: "udp", stream: false, now: 0) == true)
        #expect(table.letGo(2, now: 5) && !table.letGo(9, now: 5))
        #expect(table.data(2, query("example.org"), offset: 0, outbound: true, now: 6) == .stop([]))
        // Neither needs telling NetworkExtension again; each is forgotten idleSeconds later.
        #expect(table.expire(now: 120).isEmpty && table.count == 2)
        #expect(table.expire(now: 121).isEmpty && table.count == 1)
        #expect(table.expire(now: 125).isEmpty && table.count == 0)
        #expect(table.data(1, Data(), offset: 0, outbound: true, now: 126) == .unknown)
        // removeAll returns only the flows still being read.
        #expect(table.add(3, flow: "a", stream: false, now: 200) && table.add(4, flow: "b", stream: false, now: 200))
        #expect(table.letGo(3, now: 200) == true)
        #expect(table.removeAll() == ["b"] && table.count == 0)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

struct DNSNameTableTests {
    // outlook.office365.com on 10 November 2026: three CNAMEs of 300, 300 and 45 s, and addresses
    // of 15 s that the resolver asks for again under the chain's last name, or its middle one.
    @Test func anAddressGivenForTheEndOfAChainCountsForItsAliases() {
        let clock = Clock()
        let table = DNSNameTable(clock: { clock.now })
        let host = "outlook.office365.com", first = "outlook.cloud.microsoft"
        let middle = "acdcatm.outlook.mira.tm.svc.cloud.microsoft", last = "atm.outlook.mira.tm.svc.cloud.microsoft"
        // The whole chain, asked for by the host's name.
        table.record([learned(host, "52.96.181.98", 15)],
                     aliases: [alias(host, first, 300), alias(first, middle, 300), alias(middle, last, 45)])
        #expect(table.names(for: ip("52.96.181.98")) == [host] && table.aliases(for: ip("52.96.181.98")).isEmpty)
        // 20 s later the resolver asks for the last name only: other addresses, under that name.
        clock.advance(20)
        table.record([learned(last, "40.104.46.50", 15)])
        #expect(table.names(for: ip("40.104.46.50")) == [last])
        #expect(table.aliases(for: ip("40.104.46.50")) == [middle, first, host])
        // 30 s on, the 45 s CNAME has gone and the resolver asks for the middle name: it comes back.
        clock.advance(30)
        #expect(table.aliases(for: ip("40.104.46.50")).isEmpty)
        table.record([learned(middle, "52.96.88.2", 15)], aliases: [alias(middle, last, 45)])
        #expect(table.names(for: ip("52.96.88.2")) == [middle] && table.aliases(for: ip("52.96.88.2")) == [first, host])
        // An address nothing was said about has no alias, and the names themselves are as before.
        #expect(table.aliases(for: ip("203.0.113.1")).isEmpty && table.aliases(for: nil).isEmpty)
        // The 300 s CNAMEs go 300 s after they were read; the address's own name went before.
        clock.advance(29.5)
        #expect(table.aliases(for: ip("52.96.88.2")) == [first, host])
        clock.advance(0.5)
        #expect(table.names(for: ip("52.96.88.2")).isEmpty && table.aliases(for: ip("52.96.88.2")).isEmpty)
        table.removeAll()
        #expect(table.aliasTargetCount == 0)
    }

    @Test func aliasesLastForTheirTTLAndAreBounded() {
        #expect(DNSNameTable.aliasLifetime(ttl: 0) == 30 && DNSNameTable.aliasLifetime(ttl: 3600) == 3600)
        #expect(DNSNameTable.aliasLifetime(ttl: 172_800) == 86_400 && DNSNameTable.aliasLifetime(ttl: .max) == 86_400)
        let clock = Clock()
        let table = DNSNameTable(maximumAddresses: 2, maximumNamesPerAddress: 2, clock: { clock.now })
        table.record([learned("end.example.net", "203.0.113.7", 300)],
                     aliases: [alias("a.example.com", "end.example.net", 3600), alias("b.example.com", "end.example.net", 60)])
        #expect(table.aliases(for: ip("203.0.113.7")) == ["a.example.com", "b.example.com"])
        // A third alias of one name takes the place of the one closest to expiring.
        table.record([], aliases: [alias("c.example.com", "end.example.net", 600)])
        #expect(table.aliases(for: ip("203.0.113.7")) == ["a.example.com", "c.example.com"])
        // A third name with aliases takes the place of the one whose aliases all expire soonest.
        table.record([], aliases: [alias("x.example.com", "other.example.net", 30)])
        table.record([], aliases: [alias("y.example.com", "third.example.net", 30)])
        #expect(table.aliasTargetCount == 2 && table.aliases(for: ip("203.0.113.7")) == ["a.example.com", "c.example.com"])
        // A loop of CNAMEs ends, and a name the address has itself is not listed as its alias.
        let loop = DNSNameTable(clock: { clock.now })
        loop.record([learned("a.example.com", "203.0.113.8", 300)],
                    aliases: [alias("b.example.com", "a.example.com", 300), alias("a.example.com", "b.example.com", 300)])
        #expect(loop.aliases(for: ip("203.0.113.8")) == ["b.example.com"])
        // No more than maximumAliasesFollowed, however many there are.
        let wide = DNSNameTable(maximumNamesPerAddress: 200, clock: { clock.now })
        wide.record([learned("end.example.net", "203.0.113.9", 300)],
                    aliases: (0..<200).map { alias("n\($0).example.com", "end.example.net", 300) })
        #expect(wide.aliases(for: ip("203.0.113.9")).count == DNSNameTable.maximumAliasesFollowed)
    }

    @Test func namesLastForTheirTTLBetweenTheBounds() {
        #expect(DNSNameTable.lifetime(ttl: 0) == 30 && DNSNameTable.lifetime(ttl: 60) == 60)
        #expect(DNSNameTable.lifetime(ttl: 86_400) == 300 && DNSNameTable.lifetime(ttl: .max) == 300)
        let clock = Clock()
        let table = DNSNameTable(clock: { clock.now })
        table.record([learned("api.github.com", "140.82.121.6", 60), learned("short.example.org", "203.0.113.1", 0),
                      learned("long.example.org", "203.0.113.2", 86_400)])
        #expect(table.names(for: ip("140.82.121.6")) == ["api.github.com"])
        clock.advance(29.5)
        #expect(table.names(for: ip("203.0.113.1")) == ["short.example.org"])
        clock.advance(0.5)
        #expect(table.names(for: ip("203.0.113.1")).isEmpty)
        clock.advance(29.5)
        #expect(table.names(for: ip("140.82.121.6")) == ["api.github.com"])
        clock.advance(0.5)
        #expect(table.names(for: ip("140.82.121.6")).isEmpty)
        clock.advance(239.5)
        #expect(table.names(for: ip("203.0.113.2")) == ["long.example.org"])
        clock.advance(0.5)
        #expect(table.names(for: ip("203.0.113.2")).isEmpty)
    }

    @Test func severalNamesShareAnAddress() {
        let clock = Clock()
        let table = DNSNameTable(clock: { clock.now })
        table.record([learned("a.example.com", "203.0.113.7", 60), learned("b.example.com", "203.0.113.7", 120),
                      learned("a.example.com", "2001:db8::7", 60)])
        #expect(table.names(for: ip("203.0.113.7")) == ["a.example.com", "b.example.com"])
        #expect(table.names(for: ip("::ffff:203.0.113.7")) == ["a.example.com", "b.example.com"])
        #expect(table.names(for: ip("2001:db8::7")) == ["a.example.com"])
        #expect(table.names(for: nil).isEmpty && table.names(for: ip("198.51.100.1")).isEmpty)
        // A shorter answer does not cut a name's time short.
        table.record([learned("b.example.com", "203.0.113.7", 30)])
        clock.advance(70)
        #expect(table.names(for: ip("203.0.113.7")) == ["b.example.com"])
        clock.advance(50)
        #expect(table.names(for: ip("203.0.113.7")).isEmpty)
    }

    @Test func linkLocalAnswersTeachNothing() {
        // A DNS answer carries no interface, and a link-local address names a host only on one link.
        let clock = Clock()
        let table = DNSNameTable(clock: { clock.now })
        table.record([learned("printer.example.com", "fe80::1", 60), learned("printer.example.com", "2001:db8::9", 60)])
        #expect(table.addressCount == 1)
        #expect(table.names(for: ip("fe80::1")).isEmpty && table.names(for: ip("fe80::1%1")).isEmpty)
        #expect(table.names(for: ip("2001:db8::9")) == ["printer.example.com"])
    }

    @Test func staysBounded() {
        let clock = Clock()
        let names = DNSNameTable(maximumNamesPerAddress: 2, clock: { clock.now })
        names.record([learned("a.example.com", "203.0.113.7", 100), learned("b.example.com", "203.0.113.7", 50),
                      learned("c.example.com", "203.0.113.7", 200)])
        #expect(names.names(for: ip("203.0.113.7")) == ["a.example.com", "c.example.com"])

        let addresses = DNSNameTable(maximumAddresses: 2, clock: { clock.now })
        addresses.record([learned("x.example.com", "203.0.113.1", 100), learned("y.example.com", "203.0.113.2", 50)])
        addresses.record([learned("z.example.com", "203.0.113.3", 60)])
        #expect(addresses.addressCount == 2)
        #expect(addresses.names(for: ip("203.0.113.2")).isEmpty && !addresses.names(for: ip("203.0.113.1")).isEmpty)
        // Expired entries go first.
        clock.advance(70)
        addresses.record([learned("w.example.com", "203.0.113.4", 60)])
        #expect(addresses.names(for: ip("203.0.113.1")) == ["x.example.com"])
        #expect(addresses.names(for: ip("203.0.113.4")) == ["w.example.com"])
        addresses.removeAll()
        #expect(addresses.addressCount == 0)
    }
}
