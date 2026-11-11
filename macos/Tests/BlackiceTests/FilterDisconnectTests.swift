import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

// A content filter the kernel is still disconnecting while another has its place, read from its
// lists (FilterDisconnect).
// The filter lists are the bytes `net.cfil.filter_list` gave on 11 November 2026 (macOS 27.0.1);
// the socket records are built field by field at the offsets `net.cfil.sock_list` had that day.

/// One filter, running: id 1, no flags, 19 sockets, control unit 1.
private let running = hex("1400000001000000000000001300000001000000")
/// 09:44:45, while the kernel was held: filter 1 being disconnected (flags 2) with 22 sockets, and
/// filter 2, the new build's, with 15.
private let replacing = hex("14000000010000000200000016000000010000001400000002000000000000000f00000001000000")
/// 10:10:00, held on a socket of Tailscale's network extension: filter 1 is the new build's, with
/// 35 sockets, and filter 2 the one being disconnected, with 47.
private let replacingSecond = hex("14000000010000000000000023000000010000001400000002000000020000002f00000001000000")
/// 10:26:48, ten seconds into a `blackice stop` held the same way: filter 1 being disconnected
/// with 15 sockets, and no other filter.
private let stopping = hex("1400000001000000020000000f00000001000000")

private func hex(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// A socket's record: 136 bytes, then eight entries of 160, one for each filter it can be on. An
/// entry the socket is not on has its length and no filter.
private func socket(pid: Int32, protocol proto: Int32 = IPPROTO_UDP, filters: [UInt32]) -> Data {
    var bytes = [UInt8](repeating: 0, count: 136 + 8 * 160)
    func put(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))) }
    }
    put(UInt32(bytes.count), at: 0)
    put(UInt32(AF_INET), at: 4)
    put(UInt32(bitPattern: proto), at: 12)
    put(UInt32(bitPattern: pid), at: 32)
    put(UInt32(bitPattern: pid), at: 36)
    for entry in 0..<8 {
        put(160, at: 136 + entry * 160)
        if entry < filters.count { put(filters[entry], at: 136 + entry * 160 + 4) }
    }
    return Data(bytes)
}

/// A record `net.cfil.sock_list` gave at 09:44:45 that day, with the two process UUIDs left out:
/// a UDP socket of pid 474 (mDNSResponder), on filter 1 and on filter 2. Each pair is where bytes
/// that are not zero start, and those bytes.
private let recorded: [(Int, String)] = [
    (0, "8805"), (4, "1e"), (8, "02"), (12, "11"), (17, "350001c1b240"), (32, "da01"), (36, "8301"), (80, "56"),
    (136, "a0"), (140, "01"), (144, "03"), (148, "01"), (152, "fb3201"), (160, "c20a"), (168, "fb3201"), (176, "b80a"), (208, "56"),
    (296, "a0"), (300, "02"), (304, "01"), (308, "01"), (328, "fb3201"), (336, "b80a"),
    (456, "a0"), (488, "fb3201"), (496, "b80a"), (616, "a0"), (648, "fb3201"), (656, "b80a"),
    (776, "a0"), (808, "fb3201"), (816, "b80a"), (936, "a0"), (968, "fb3201"), (976, "b80a"),
    (1096, "a0"), (1128, "fb3201"), (1136, "b80a"), (1256, "a0"), (1288, "fb3201"), (1296, "b80a"),
]

@Suite struct FilterDisconnectTests {
    @Test func readsARecordAsTheKernelGaveIt() {
        var bytes = [UInt8](repeating: 0, count: 1416)
        for (offset, text) in recorded { bytes.replaceSubrange(offset..<offset + text.count / 2, with: hex(text)) }
        #expect(FilterDisconnect(filters: replacing, sockets: Data(bytes)) == FilterDisconnect(pid: 474, udp: true))
        // The record the helper builds is laid out the same way.
        #expect(FilterDisconnect(filters: replacing, sockets: socket(pid: 474, filters: [1, 2]))
            == FilterDisconnect(filters: replacing, sockets: Data(bytes)))
    }

    @Test func aRunningFilterIsNotOne() {
        #expect(FilterDisconnect.count(filters: running) == 1)
        #expect(!FilterDisconnect.going(filters: running))
        #expect(FilterDisconnect(filters: running, sockets: socket(pid: 474, filters: [1])) == nil)
        #expect(FilterDisconnect.count(filters: Data()) == 0)
        #expect(!FilterDisconnect.going(filters: Data()))
        #expect(FilterDisconnect(filters: Data(), sockets: Data()) == nil)
    }

    // No new socket is attached to a filter that is going when none runs in its place: in the stop
    // these bytes are from, lookups went on as before.
    @Test func aFilterGoingWithNoneInItsPlaceIsNotOne() {
        let sockets = socket(pid: 34464, filters: [1])
        #expect(FilterDisconnect.going(filters: stopping))
        #expect(FilterDisconnect(filters: stopping, sockets: sockets) == nil)
        // Nor when the filter that runs is another product's, registered for another control unit.
        var other = [UInt8](replacing)
        other[36] = 0x02
        #expect(FilterDisconnect.going(filters: Data(other)))
        #expect(FilterDisconnect(filters: Data(other), sockets: sockets) == nil)
        // One registered for that unit among others is in its place.
        other[36] = 0x03
        #expect(FilterDisconnect(filters: Data(other), sockets: sockets) == FilterDisconnect(pid: 34464, udp: true))
    }

    // What an upgrade waits on with the filter off: the filter going is read with none in its place.
    @Test func readsAFilterGoingWithNoneInItsPlaceWhenAsked() {
        let sockets = socket(pid: 86450, filters: [0]) + socket(pid: 34464, filters: [1])
        #expect(FilterDisconnect(filters: stopping, sockets: sockets, replacedOnly: false) == FilterDisconnect(pid: 34464, udp: true))
        #expect(FilterDisconnect(filters: running, sockets: sockets, replacedOnly: false) == nil)
        #expect(FilterDisconnect(filters: replacing, sockets: sockets, replacedOnly: false) == FilterDisconnect(pid: 34464, udp: true))
    }

    @Test func saysHowFarTheKernelIsWithAFilterTurnedOff() {
        // The three lists of the stop of 11 November: before the kernel was told, while it was
        // held, and after.
        #expect(FilterDisconnect.progress(filters: running, before: 1) == .pending)
        #expect(FilterDisconnect.progress(filters: stopping, before: 1) == .going)
        #expect(FilterDisconnect.progress(filters: Data(), before: 1) == .gone)
        // With another product's filter beside it.
        #expect(FilterDisconnect.progress(filters: replacing, before: 2) == .going)
        #expect(FilterDisconnect.progress(filters: running, before: 2) == .gone)
        // A filter that was not in the list has none to wait for.
        #expect(FilterDisconnect.progress(filters: Data(), before: 0) == .pending)
        #expect(FilterDisconnect.progress(filters: stopping.prefix(19), before: 1) == nil)
    }

    @Test func waitsForAFilterGoingUpToTheLimit() {
        // An upgrade turns the filter off itself: the kernel is told a moment later.
        #expect(FilterDisconnect.wait(.pending, waited: 0.1, appear: 2, limit: 30) == .again)
        #expect(FilterDisconnect.wait(.pending, waited: 2, appear: 2, limit: 30) == .done)
        #expect(FilterDisconnect.wait(.going, waited: 29.9, appear: 2, limit: 30) == .again)
        #expect(FilterDisconnect.wait(.going, waited: 30, appear: 2, limit: 30) == .tooLong)
        #expect(FilterDisconnect.wait(.gone, waited: 0, appear: 2, limit: 30) == .done)
        // A start after a stop: only a filter already going is waited for.
        #expect(FilterDisconnect.wait(.pending, waited: 0, appear: 0, limit: 30) == .done)
        #expect(FilterDisconnect.wait(.going, waited: 0, appear: 0, limit: 30) == .again)
        #expect(FilterDisconnect.wait(.going, waited: 30, appear: 0, limit: 30) == .tooLong)
        // The list as that stop left it, read as start does, with the filters it has then.
        #expect(FilterDisconnect.progress(filters: stopping, before: FilterDisconnect.count(filters: stopping)!) == .going)
        #expect(FilterDisconnect.progress(filters: Data(), before: FilterDisconnect.count(filters: stopping)!) == .gone)
        #expect(FilterDisconnect.progress(filters: Data(), before: 0) == .pending)
    }

    @Test func startSaysWhatItWaitsForWithTheFilterOff() {
        let tailscale = HeldDisconnect(FilterDisconnect(pid: 86450, udp: true), process: "io.tailscale.ipn.macsys.network-extension")
        #expect(CLI.turnedOffLines(tailscale, limit: 30) == [
            "macOS is still disconnecting the filter that was running. Until it is done blackice stays off and connections are not checked, for 30 s at most.",
            "It waits on a UDP socket of io.tailscale.ipn.macsys.network-extension (pid 86450): it is done when that socket closes or sends to another address.",
        ])
        #expect(CLI.turnedOffLines(HeldDisconnect(FilterDisconnect(pid: nil, udp: false), process: nil), limit: 30).count == 1)
        #expect(CLI.turnedOffTooLong(limit: 30) == "macOS is not done after 30 s. Starting the filter anyway.")
    }

    @Test func theFilterGoingCanBeTheSecondListed() {
        #expect(FilterDisconnect.going(filters: replacingSecond))
        let sockets = socket(pid: 474, filters: [1]) + socket(pid: 86450, filters: [1, 2]) + socket(pid: 16441, filters: [0, 2])
        #expect(FilterDisconnect(filters: replacingSecond, sockets: sockets) == FilterDisconnect(pid: 86450, udp: true))
    }

    @Test func namesTheFirstSocketStillOnTheFilterThatIsGoing() {
        #expect(FilterDisconnect.count(filters: replacing) == 2)
        #expect(FilterDisconnect.going(filters: replacing))
        // Sockets the kernel already took off filter 1, one on the new filter only, then the one it
        // is at, then newer ones on both.
        let sockets = socket(pid: 76648, filters: []) + socket(pid: 86450, protocol: IPPROTO_TCP, filters: [0, 2])
            + socket(pid: 16441, filters: [1]) + socket(pid: 474, filters: [1, 2]) + socket(pid: 55343, protocol: IPPROTO_TCP, filters: [1, 2])
        #expect(FilterDisconnect(filters: replacing, sockets: sockets) == FilterDisconnect(pid: 16441, udp: true))
        // Read from wherever the bytes start.
        let shifted = (Data([0xff, 0xff]) + replacing).dropFirst(2)
        #expect(FilterDisconnect(filters: shifted, sockets: (Data([0xff]) + sockets).dropFirst(1)) == FilterDisconnect(pid: 16441, udp: true))
    }

    @Test func saysWhenItIsNotAUDPSocketOrNoProcess() {
        #expect(FilterDisconnect(filters: replacing, sockets: socket(pid: 55343, protocol: IPPROTO_TCP, filters: [1, 2]))
            == FilterDisconnect(pid: 55343, udp: false))
        // The kernel's own sockets have no process.
        #expect(FilterDisconnect(filters: replacing, sockets: socket(pid: 0, filters: [1])) == FilterDisconnect(pid: nil, udp: true))
    }

    @Test func namesNoSocketWhenTheListHasNoneOrIsLaidOutAnotherWay() {
        let none = FilterDisconnect(pid: nil, udp: false)
        #expect(FilterDisconnect(filters: replacing, sockets: Data()) == none)
        #expect(FilterDisconnect(filters: replacing, sockets: socket(pid: 474, filters: [2])) == none)
        // A record cut short, one whose length is not a header and whole entries, and one that
        // says it is longer than what is there.
        let whole = socket(pid: 16441, filters: [1])
        #expect(FilterDisconnect(filters: replacing, sockets: whole.prefix(100)) == none)
        var odd = [UInt8](whole)
        odd[0] = 0x89
        #expect(FilterDisconnect(filters: replacing, sockets: Data(odd)) == none)
        #expect(FilterDisconnect(filters: replacing, sockets: whole.prefix(1000)) == none)
        // What is readable before a bad record still counts.
        #expect(FilterDisconnect(filters: replacing, sockets: whole + whole.prefix(100)) == FilterDisconnect(pid: 16441, udp: true))
    }

    @Test func saysNothingWhenTheFiltersAreLaidOutAnotherWay() {
        let sockets = socket(pid: 16441, filters: [1])
        // Not whole records, and a record of another length.
        #expect(FilterDisconnect.count(filters: replacing.prefix(39)) == nil)
        #expect(FilterDisconnect(filters: replacing.prefix(39), sockets: sockets) == nil)
        var other = [UInt8](replacing)
        other[0] = 0x18
        #expect(FilterDisconnect.count(filters: Data(other)) == nil)
        #expect(!FilterDisconnect.going(filters: Data(other)))
        #expect(FilterDisconnect(filters: Data(other), sockets: sockets) == nil)
    }

    @Test func startSaysWhatHoldsTheNetwork() {
        let python = HeldDisconnect(FilterDisconnect(pid: 16441, udp: true), process: "Python")
        #expect(CLI.heldLines(python) == [
            "macOS is still disconnecting the filter that stopped, and until it is done no new connection gets through.",
            "It waits on a UDP socket of Python (pid 16441): it is done when that socket closes or sends to another address.",
            "blackice status says so while it lasts.",
        ])
        #expect(CLI.heldLines(HeldDisconnect(FilterDisconnect(pid: nil, udp: false), process: nil)) == [
            "macOS is still disconnecting the filter that stopped, and until it is done no new connection gets through.",
            "blackice status says so while it lasts.",
        ])
        // A process whose name could not be read, and a name that would write to the terminal.
        #expect(CLI.heldLines(HeldDisconnect(FilterDisconnect(pid: 7, udp: false), process: nil))[1]
            == "It waits on a socket of a process (pid 7): it is done when that socket closes or sends to another address.")
        #expect(!CLI.heldLines(HeldDisconnect(FilterDisconnect(pid: 7, udp: true), process: "a\u{1b}[2Jb"))[1].contains("\u{1b}"))
    }

    @Test func statusSaysItWhateverTheFilterIs() {
        let held = HeldDisconnect(FilterDisconnect(pid: 474, udp: true), process: "mDNSResponder")
        #expect(CLI.statusLines(StatusReport(filter: .notConfigured, daemonRunning: false, pending: nil, held: held)) == [
            "blackice is off. Start it: blackice start",
            "  network    no new connection gets through: macOS is still disconnecting the filter that stopped, " +
                "and waits on a UDP socket of mDNSResponder (pid 474)",
        ])
        let unnamed = HeldDisconnect(FilterDisconnect(pid: nil, udp: false), process: nil)
        #expect(CLI.statusLines(StatusReport(filter: .disabled, daemonRunning: false, pending: nil, held: unnamed)).last
            == "  network    no new connection gets through: macOS is still disconnecting the filter that stopped")
        #expect(CLI.statusLines(StatusReport(filter: .notConfigured, daemonRunning: false, pending: nil)).count == 1)
    }
}
