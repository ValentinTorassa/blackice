import Foundation

// A content filter the kernel is still disconnecting while another has its place, read from the
// kernel's own lists (docs/plan.md, "A replacement that holds the network").
//
// When a filter's provider stops, the kernel detaches the sockets attached to that filter one by
// one. On macOS 27.0.1 it does not get past a UDP socket whose flow table had two flows and has
// one left: it looks the flow up, is told there is none, leaves the socket on the filter's list
// and takes the list's first socket again, which is the same one. Until that socket closes or
// gets another flow the filter stays registered. Once it stayed at another kind: an ICMP datagram
// socket of macOS's symptomsd with one flow, for 58.9 s on 11 November 2026.
//
// What that does depends on whether a filter runs in its place. The kernel attaches a new socket
// to every filter registered for a control unit the socket's policy names, one that is going
// included (xnu's `cfil_info_attach_unit`). On 11 November 2026, in a replacement (the new build's
// filter running, with the control unit of the one going), each new socket joined both, the one
// going gave no verdict, and no new connection got through: for 4.1 s, for 25.8 s on a socket of
// Tailscale's network extension, and for 10.2 s with a test socket kept open that long. In a
// `blackice stop` held 10.1 s the same way, with no filter in its place, the one going kept its
// 15 sockets and got no new one, and a lookup a second went on in 0.21 s or less.
//
// At an ICMP socket bound to no address blackice can end it. Three upgrades on 11 November 2026
// were held at one of symptomsd's, for 58.9, 47.3 and 116.0 s: each time the kernel let go 17 to
// 29 s after the new filter had stopped every new connection, and in the second and the third the
// socket's record in the kernel's list began again with its first 180 bytes within 0.3 s of that.
// In a `blackice stop` held 8.0 s at that socket, one `ping` of 127.0.0.1 ended it within 0.01 s:
// the reply to an echo request goes to every ICMP socket bound to no address. So while it waits
// for a filter that is going, the CLI sends an echo request to this Mac's own loopback address
// (echoRequest, echoDue; KernelFilters.gone).
//
// At a UDP socket blackice cannot end it. It can keep a new filter out of it, by starting that
// filter once the old one is gone (NESystemControl.start), and say that it is happening and whose
// socket it is:
// the kernel publishes its filters (`net.cfil.filter_list`) and the sockets attached to them
// (`net.cfil.sock_list`), in the order the filter's own list has, to any process.
public struct FilterDisconnect: Equatable, Sendable {
    /// The process that has the first socket still attached to the filter that is going, which is
    /// the one the kernel is at. nil when the list of sockets names none or is laid out another way.
    public let pid: Int32?
    /// Whether that socket is a UDP one, the kind seen to hold a disconnect every time but one.
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
    /// cfs_necp_control_unit: the control units a filter is registered for, one bit each.
    static let filterUnits = 16
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

    /// Whether `net.cfil.filter_list` has a filter the kernel is disconnecting, with or without
    /// another in its place.
    public static func going(filters: Data) -> Bool {
        guard count(filters: filters) != nil else { return false }
        return goingRecord([UInt8](filters)) != nil
    }

    /// What `net.cfil.filter_list` says of a filter that was turned off when the list had a
    /// number of filters.
    public enum Progress: Equatable, Sendable {
        /// As many filters as before and none being disconnected: the kernel has not been told yet.
        case pending
        /// The kernel is disconnecting a filter.
        case going
        /// Fewer filters than before and none being disconnected.
        case gone
    }

    /// nil when the list is not laid out as above.
    public static func progress(filters: Data, before: Int) -> Progress? {
        guard let now = count(filters: filters) else { return nil }
        if goingRecord([UInt8](filters)) != nil { return .going }
        return now < before ? .gone : .pending
    }

    /// What waiting for a filter that was turned off does next.
    public enum Wait: Equatable, Sendable {
        /// Nothing is left to wait for.
        case done
        /// Read the list again.
        case again
        /// The kernel is still disconnecting the filter after the limit.
        case tooLong
    }

    /// `waited` seconds after the filter was turned off. A list that still has as many filters as
    /// before and none going is waited on for `appear` seconds, since the stop reaches the kernel a
    /// moment after it is asked for; a filter going, for `limit` seconds. With `appear` 0 only a
    /// filter already going is waited for: the one a `blackice stop` a moment ago left.
    public static func wait(_ progress: Progress, waited: TimeInterval, appear: TimeInterval, limit: TimeInterval) -> Wait {
        switch progress {
        case .gone: return .done
        case .pending: return waited >= appear ? .done : .again
        case .going: return waited >= limit ? .tooLong : .again
        }
    }

    /// Whether to send an echo request now: `going` seconds after a filter was first seen going,
    /// `last` seconds after the echo request before, if any. The first 0.3 s in, since a disconnect
    /// that goes well is over in milliseconds, then one every 2 s while it lasts.
    public static func echoDue(going: TimeInterval, last: TimeInterval?) -> Bool {
        last.map { $0 >= 2 } ?? (going >= 0.3)
    }

    /// An ICMP echo request with no data, as a datagram ICMP socket sends it: type 8, code 0, the
    /// Internet checksum, then `id` and `sequence`.
    public static func echoRequest(id: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        var sum: UInt32 = 0
        for index in stride(from: 0, to: packet.count, by: 2) {
            sum += UInt32(packet[index]) << 8 | UInt32(packet[index + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(truncatingIfNeeded: sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)
        return packet
    }

    private static func goingRecord(_ list: [UInt8]) -> Int? {
        stride(from: 0, to: list.count, by: filterRecord).first { word(list, $0 + filterFlags) & detaching != 0 }
    }

    /// From `net.cfil.filter_list` and `net.cfil.sock_list`. nil when the kernel is disconnecting
    /// no filter, when no other filter runs with a control unit of the one going, so that no new
    /// socket waits on it, and when the list of filters is not laid out as above: then nothing is
    /// said. With `replacedOnly` false, a filter going with none in its place is read too.
    public init?(filters: Data, sockets: Data, replacedOnly: Bool = true) {
        guard Self.count(filters: filters) != nil else { return nil }
        let list = [UInt8](filters)
        guard let filter = Self.goingRecord(list) else { return nil }
        let going = Self.word(list, filter + 4)
        let units = Self.word(list, filter + Self.filterUnits)
        guard going != 0, !replacedOnly || stride(from: 0, to: list.count, by: Self.filterRecord).contains(where: {
            Self.word(list, $0 + Self.filterFlags) & Self.detaching == 0 && Self.word(list, $0 + Self.filterUnits) & units != 0
        }) else { return nil }

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
