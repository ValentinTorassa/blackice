import Foundation

// A content filter the kernel is still disconnecting, read from the kernel's own lists
// (docs/plan.md, "A replacement that stops the network").
//
// When a filter's provider stops, the kernel detaches the sockets attached to that filter one by
// one. On macOS 27.0.1 it does not get past a UDP socket whose flow table had two flows and has
// one left: it looks the flow up, is told there is none, leaves the socket on the filter's list
// and takes the list's first socket again, which is the same one. Until that socket closes or
// gets another flow the filter stays registered, every new socket is attached to it, and none
// gets a verdict: no new connection gets through. On 11 November 2026 a replacement held that way
// for 4.1 s, and for 10.2 s with a test socket kept open that long.
//
// blackice cannot end it. It can say that it is happening and whose socket it is: the kernel
// publishes its filters (`net.cfil.filter_list`) and the sockets attached to them
// (`net.cfil.sock_list`), in the order the filter's own list has, to any process.
public struct FilterDisconnect: Equatable, Sendable {
    /// The process that has the first socket still attached to the filter that is going, which is
    /// the one the kernel is at. nil when the list of sockets names none or is laid out another way.
    public let pid: Int32?
    /// Whether that socket is a UDP one, the kind seen to hold a disconnect.
    public let udp: Bool

    public init(pid: Int32?, udp: Bool) {
        self.pid = pid
        self.udp = udp
    }

    // struct cfil_filter_stat and struct cfil_sock_stat of xnu's bsd/net/content_filter.h, as
    // macOS 27.0.1 fills them: five 32-bit fields a filter; for a socket 136 bytes, then one
    // struct cfil_entry_stat of 160 bytes for each filter it can be on.
    static let filterRecord = 20
    static let filterFlags = 8
    /// CFF_DETACHING.
    static let detaching: UInt32 = 0x2
    static let socketHeader = 136
    static let socketProtocol = 12
    static let socketPID = 32
    static let entryRecord = 160
    static let entryFilter = 4

    /// How many filters `net.cfil.filter_list` holds; nil when it is not laid out as above.
    public static func count(filters: Data) -> Int? {
        let bytes = [UInt8](filters)
        guard bytes.count % filterRecord == 0 else { return nil }
        for record in stride(from: 0, to: bytes.count, by: filterRecord) {
            guard word(bytes, record) == UInt32(filterRecord) else { return nil }
        }
        return bytes.count / filterRecord
    }

    /// From `net.cfil.filter_list` and `net.cfil.sock_list`. nil when the kernel is disconnecting
    /// no filter, and when the list of filters is not laid out as above: then nothing is said.
    public init?(filters: Data, sockets: Data) {
        guard Self.count(filters: filters) != nil else { return nil }
        let list = [UInt8](filters)
        var going: UInt32?
        for record in stride(from: 0, to: list.count, by: Self.filterRecord)
        where Self.word(list, record + Self.filterFlags) & Self.detaching != 0 {
            going = Self.word(list, record + 4)
            break
        }
        guard let going, going != 0 else { return nil }

        let bytes = [UInt8](sockets)
        var record = 0
        while record + Self.socketHeader <= bytes.count {
            let length = Int(Self.word(bytes, record))
            guard length >= Self.socketHeader, (length - Self.socketHeader) % Self.entryRecord == 0,
                  record + length <= bytes.count else { break }
            for entry in stride(from: record + Self.socketHeader, to: record + length, by: Self.entryRecord)
            where Self.word(bytes, entry + Self.entryFilter) == going {
                let owner = Int32(bitPattern: Self.word(bytes, record + Self.socketPID))
                pid = owner > 0 ? owner : nil
                udp = Int32(bitPattern: Self.word(bytes, record + Self.socketProtocol)) == IPPROTO_UDP
                return
            }
            record += length
        }
        pid = nil
        udp = false
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
