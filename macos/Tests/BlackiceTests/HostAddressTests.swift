import Foundation
import Testing
@testable import BlackiceCore

/// Answers from a table, counting lookups. nil in the table means the lookup fails.
private final class FakeResolver: HostResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [String]?]
    private var counts: [String: Int] = [:]

    init(_ table: [String: [String]?]) { self.table = table }

    func resolve(_ host: String) -> [IPAddress]? {
        lock.lock(); defer { lock.unlock() }
        counts[host, default: 0] += 1
        guard let entry = table[host], let list = entry else { return nil }
        return list.compactMap(IPAddress.init)
    }

    func set(_ host: String, _ answers: [String]?) {
        lock.lock(); defer { lock.unlock() }
        table[host] = answers
    }

    func lookups(_ host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[host] ?? 0
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

/// Fails every lookup after holding it for `seconds` of `clock`, as a resolver that times out.
private final class TimingOutResolver: HostResolving, @unchecked Sendable {
    private let clock: Clock
    private let seconds: TimeInterval

    init(_ clock: Clock, seconds: TimeInterval) {
        self.clock = clock
        self.seconds = seconds
    }

    func resolve(_ host: String) -> [IPAddress]? {
        clock.advance(seconds)
        return nil
    }
}

private func ip(_ text: String) -> IPAddress { IPAddress(text)! }

struct IPAddressTests {
    @Test func parsesAndPrintsBothFamilies() {
        #expect(IPAddress("203.0.113.7")?.bytes == [203, 0, 113, 7])
        #expect(IPAddress("203.0.113.7")?.description == "203.0.113.7")
        #expect(IPAddress("2001:DB8:0:0::1")?.description == "2001:db8::1")
        #expect(IPAddress("2001:db8::1")?.bytes.count == 16)
    }

    @Test func mappedAddressesCompareEqual() {
        #expect(IPAddress("::ffff:203.0.113.7") == IPAddress("203.0.113.7"))
        #expect(IPAddress("::ffff:203.0.113.7")?.description == "203.0.113.7")
        // A zone means nothing for an address that is not link-local.
        #expect(IPAddress("2001:db8::1%en0") == IPAddress("2001:db8::1"))
        #expect(IPAddress("2001:db8::1%7")?.scope == 0 && IPAddress("203.0.113.7%7")?.scope == 0)
    }

    @Test func aSocketAddressGivesTheAddressAndALinkLocalInterface() throws {
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_scope_id = 7
        #expect(inet_pton(AF_INET6, "fe80::dead:beef", &v6.sin6_addr) == 1)
        func read(_ address: inout sockaddr_in6) -> IPAddress? {
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress(socketAddress: $0) } }
        }
        let linkLocal = try #require(read(&v6))
        #expect(linkLocal.scope == 7 && linkLocal.isCheckable && linkLocal.description == "fe80::dead:beef%7")
        #expect(linkLocal == IPAddress("fe80::dead:beef%7"))
        // With no interface it is not checkable, as from text.
        v6.sin6_scope_id = 0
        #expect(read(&v6) == IPAddress("fe80::dead:beef") && read(&v6)?.isCheckable == false)
        // Only a link-local address keeps an interface, and an IPv4-mapped one is IPv4.
        v6.sin6_scope_id = 7
        #expect(inet_pton(AF_INET6, "2001:db8::1", &v6.sin6_addr) == 1)
        #expect(read(&v6) == IPAddress("2001:db8::1") && read(&v6)?.scope == 0)
        #expect(inet_pton(AF_INET6, "::ffff:192.0.2.7", &v6.sin6_addr) == 1)
        #expect(read(&v6) == IPAddress("192.0.2.7"))
        var v4 = sockaddr_in()
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        #expect(inet_pton(AF_INET, "192.0.2.7", &v4.sin_addr) == 1)
        let fromV4 = withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress(socketAddress: $0) } }
        #expect(fromV4 == IPAddress("192.0.2.7"))
        // Another family is not an address.
        var local = sockaddr()
        local.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        local.sa_family = sa_family_t(AF_UNIX)
        #expect(IPAddress(socketAddress: &local) == nil)
    }

    @Test func linkLocalAddressesKeepTheirInterface() throws {
        // The same link-local address on two links can be two hosts.
        let loopback = if_nametoindex("lo0")
        #expect(loopback != 0)
        #expect(IPAddress("fe80::1%lo0")?.scope == loopback)
        #expect(IPAddress("fe80::1%lo0") == IPAddress("fe80::1%\(loopback)"))
        #expect(IPAddress("fe80::1%1") != IPAddress("fe80::1%2"))
        #expect(IPAddress("fe80::1%1") != IPAddress("fe80::1"))
        #expect(IPAddress("FE80::1%3")?.description == "fe80::1%3")
        #expect(IPAddress("fe80::1")?.description == "fe80::1")
        // The description reads back as the same address, as HookEvent requires.
        let scoped = try #require(IPAddress("fe80::abcd%9"))
        #expect(IPAddress(scoped.description) == scoped)
        let event = try HookEvent.connection(app: .init(signingID: "com.example.tool", teamID: "ABCDE12345", path: nil),
                                             host: "printer.example.com", ip: scoped.description, port: 443,
                                             deadline: Date().addingTimeInterval(30))
        try event.validate(now: Date())
        #expect(IPAddress(bytes: scoped.bytes, scope: 9) == scoped)
        #expect(IPAddress(bytes: [203, 0, 113, 7], scope: 9)?.scope == 0)
        // Without a known interface it may be any host on any link.
        #expect(IPAddress("fe80::1")?.isCheckable == false)
        #expect(IPAddress("fe80::1%nosuchif9")?.scope == 0)
        #expect(IPAddress("fe80::1%nosuchif9")?.isCheckable == false)
        #expect(IPAddress("fe80::1%1")?.isCheckable == true)
        #expect(IPAddress("2001:db8::1")?.isCheckable == true && IPAddress("203.0.113.7")?.isCheckable == true)
    }

    @Test func refusesEverythingElse() {
        for bad in ["", "example.com", "203.0.113", "203.0.113.256", "0x7f.1", "127.1", "1.2.3.4 ", " 1.2.3.4",
                    "2001:db8::1::2", "%en0", String(repeating: "1", count: 100), "1.2.3.4\u{0}",
                    "fe80::1%", "fe80::1%" + String(repeating: "e", count: 16), "fe80::1%en\u{0}"] {
            #expect(IPAddress(bad) == nil, "\(bad)")
        }
        #expect(IPAddress(bytes: [1, 2, 3]) == nil)
    }
}

struct HostAddressCacheTests {
    @Test func unknownUntilLookedUp() {
        let resolver = FakeResolver(["api.example.com": ["203.0.113.7"]])
        let cache = HostAddressCache(resolver: resolver)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .unknown)
        #expect(resolver.lookups("api.example.com") == 0)
        #expect(cache.lookUp("api.example.com") == [ip("203.0.113.7")])
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .match)
        #expect(resolver.lookups("api.example.com") == 1)
    }

    @Test func cdnStyleAnswersMatchAnyOfThem() {
        let cdn = ["198.51.100.1", "198.51.100.2", "203.0.113.7", "2001:db8::7"]
        let cache = HostAddressCache(resolver: FakeResolver(["cdn.example.com": cdn]))
        cache.lookUp("cdn.example.com")
        for address in cdn { #expect(cache.check(host: "cdn.example.com", address: ip(address)) == .match) }
        #expect(cache.check(host: "cdn.example.com", address: ip("::ffff:198.51.100.2")) == .match)
    }

    @Test func anotherAddressIsAMismatch() {
        let cache = HostAddressCache(resolver: FakeResolver(["api.example.com": ["198.51.100.1", "198.51.100.2"]]))
        cache.lookUp("api.example.com")
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .mismatch)
        #expect(cache.check(host: "api.example.com", address: nil) == .mismatch)
        // Another host's answers say nothing about this one.
        #expect(cache.check(host: "www.example.com", address: ip("198.51.100.1")) == .unknown)
    }

    @Test func linkLocalAnswersMatchOnlyTheirInterface() {
        let cache = HostAddressCache(resolver: FakeResolver(["printer.local": ["fe80::1%1", "2001:db8::7"]]))
        cache.lookUp("printer.local")
        #expect(cache.check(host: "printer.local", address: ip("fe80::1%1")) == .match)
        // The same address on another link, or on a link nobody named, is not the printer.
        #expect(cache.check(host: "printer.local", address: ip("fe80::1%2")) == .mismatch)
        #expect(cache.check(host: "printer.local", address: ip("fe80::1")) == .mismatch)
        #expect(cache.check(host: "printer.local", address: ip("2001:db8::7%2")) == .match)
        // An answer with no interface matches nothing, not even the same spelling.
        #expect(HostAddressCache.check(ip("fe80::1"), against: [ip("fe80::1")]) == .mismatch)
    }

    // A failed lookup matches no address, and the check says the lookup failed.
    @Test func failedLookupMismatchesEverything() {
        let cache = HostAddressCache(resolver: FakeResolver(["gone.example.com": nil]))
        #expect(cache.lookUp("gone.example.com").isEmpty)
        #expect(cache.check(host: "gone.example.com", address: ip("203.0.113.7")) == .lookupFailed)
        #expect(cache.checkOrRefresh(host: "gone.example.com", address: ip("203.0.113.7")) == .lookupFailed)
        #expect(cache.check(host: "gone.example.com", address: ip("fe80::1")) == .lookupFailed)
        #expect(HostAddressCache.check(ip("203.0.113.7"), against: []) == .lookupFailed)
    }

    @Test func answersExpireAfterTheTTL() {
        let resolver = FakeResolver(["api.example.com": ["203.0.113.7"]])
        let clock = Clock()
        let cache = HostAddressCache(resolver: resolver, ttl: 30, clock: { clock.now })
        cache.lookUp("api.example.com")
        clock.advance(29.9)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .match)
        clock.advance(0.1)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .unknown)
        // DNS moved meanwhile: the next lookup sees it.
        resolver.set("api.example.com", ["198.51.100.9"])
        cache.lookUp("api.example.com")
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .mismatch)
        #expect(resolver.lookups("api.example.com") == 2)
    }

    @Test func aMissAgainstOlderAnswersIsLookedUpAgain() {
        // A CDN that rotates its addresses every few seconds, as outlook.office365.com does.
        let resolver = FakeResolver(["outlook.example.com": ["52.97.28.130", "52.97.51.82"]])
        let clock = Clock()
        let cache = HostAddressCache(resolver: resolver, ttl: 30, clock: { clock.now })
        cache.lookUp("outlook.example.com")
        let rotated = ip("52.97.106.50")
        // Answers just looked up are what the resolver says now: a miss is a miss.
        clock.advance(1)
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: rotated) == .mismatch)
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: ip("52.97.51.82")) == .match)
        // Older ones that miss it are looked up again, and the new answers decide.
        clock.advance(HostAddressCache.refreshAfter)
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: rotated) == .unknown)
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: ip("52.97.28.130")) == .match)
        // The plain check, for a flow that cannot wait, still calls it a mismatch.
        #expect(cache.check(host: "outlook.example.com", address: rotated) == .mismatch)
        resolver.set("outlook.example.com", ["52.97.106.50", "52.97.23.210"])
        cache.lookUp("outlook.example.com")
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: rotated) == .match)
        // An address that is not among the new answers either stays a mismatch until they age.
        let elsewhere = ip("203.0.113.7")
        #expect(cache.checkOrRefresh(host: "outlook.example.com", address: elsewhere) == .mismatch)
        #expect(resolver.lookups("outlook.example.com") == 2)
    }

    @Test func anUncheckableAddressIsNotLookedUpAgain() {
        let clock = Clock()
        let cache = HostAddressCache(resolver: FakeResolver(["printer.local": ["fe80::1%1"]]), ttl: 30, clock: { clock.now })
        cache.lookUp("printer.local")
        clock.advance(10)
        #expect(cache.checkOrRefresh(host: "printer.local", address: ip("fe80::1")) == .mismatch)
        #expect(cache.checkOrRefresh(host: "printer.local", address: nil) == .mismatch)
        // Expired answers are unknown, as with check.
        clock.advance(20)
        #expect(cache.checkOrRefresh(host: "printer.local", address: ip("fe80::1")) == .unknown)
    }

    // A failed lookup counts for 2 s, not 30: one timeout of the resolver (Tailscale's
    // 100.100.100.100, a network that changed, a Mac just awake) dropped every connection to the
    // host for the whole 30 s, those a rule or an approval covers included.
    @Test func aFailedLookupIsLookedUpAgainAfterTwoSeconds() {
        let resolver = FakeResolver(["api.example.com": nil])
        let clock = Clock()
        let cache = HostAddressCache(resolver: resolver, ttl: 30, clock: { clock.now })
        #expect(cache.lookUp("api.example.com").isEmpty)
        // Meanwhile it is a mismatch, plain or refreshed, so a burst costs no more lookups, and
        // the cache says why.
        clock.advance(1.5)
        #expect(cache.checkOrRefresh(host: "api.example.com", address: ip("203.0.113.7")) == .lookupFailed)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .lookupFailed)
        #expect(cache.check(host: "other.example.com", address: ip("203.0.113.7")) == .unknown)
        // The resolver comes back; 2 s after the failure the host is looked up again.
        #expect(resolver.lookups("api.example.com") == 1)
        resolver.set("api.example.com", ["203.0.113.7"])
        clock.advance(0.5)
        #expect(cache.checkOrRefresh(host: "api.example.com", address: ip("203.0.113.7")) == .unknown)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .unknown)
        cache.lookUp("api.example.com")
        #expect(cache.checkOrRefresh(host: "api.example.com", address: ip("203.0.113.7")) == .match)
        #expect(resolver.lookups("api.example.com") == 2)
        // Answers that were found last the whole 30 s, as before.
        clock.advance(29.9)
        #expect(cache.check(host: "api.example.com", address: ip("203.0.113.7")) == .match)
        // Never longer than the cache's own time either.
        let short = HostAddressCache(resolver: FakeResolver(["gone.example.com": nil]), ttl: 1, clock: { clock.now })
        short.lookUp("gone.example.com")
        clock.advance(1)
        #expect(short.checkOrRefresh(host: "gone.example.com", address: ip("203.0.113.7")) == .unknown)
    }

    // While a host's lookups keep failing, each failure counts twice as long as the one before,
    // up to the cache's own time: 2, 4, 8, 16, then 30 s. Offline, or with a resolver that times
    // out, apps keep trying every host they use, and a lookup of each every 2 s held a thread for
    // the resolver's whole timeout. Answers end the run, and the next failure counts 2 s again.
    @Test func failedLookupsInARowCountLongerUpToTheTTL() {
        let resolver = FakeResolver(["api.example.com": nil])
        let clock = Clock()
        let cache = HostAddressCache(resolver: resolver, ttl: 30, clock: { clock.now })
        let address = ip("203.0.113.7")
        func failure(counts seconds: TimeInterval) {
            #expect(cache.lookUp("api.example.com").isEmpty)
            clock.advance(seconds - 0.5)
            #expect(cache.checkOrRefresh(host: "api.example.com", address: address) == .lookupFailed, "\(seconds) s")
            clock.advance(0.5)
            #expect(cache.checkOrRefresh(host: "api.example.com", address: address) == .unknown, "\(seconds) s")
        }
        for seconds: TimeInterval in [2, 4, 8, 16, 30, 30, 30] { failure(counts: seconds) }
        #expect(resolver.lookups("api.example.com") == 7)
        resolver.set("api.example.com", ["203.0.113.7"])
        cache.lookUp("api.example.com")
        clock.advance(29.5)
        #expect(cache.checkOrRefresh(host: "api.example.com", address: address) == .match)
        clock.advance(0.5)
        resolver.set("api.example.com", nil)
        for seconds: TimeInterval in [2, 4, 8] { failure(counts: seconds) }
        // Another host's run is its own.
        let other = HostAddressCache(resolver: FakeResolver(["a.example.com": nil, "b.example.com": nil]), ttl: 30,
                                     clock: { clock.now })
        other.lookUp("a.example.com")
        clock.advance(2)
        other.lookUp("a.example.com")
        other.lookUp("b.example.com")
        clock.advance(2)
        #expect(other.check(host: "a.example.com", address: address) == .lookupFailed)
        #expect(other.check(host: "b.example.com", address: address) == .unknown)
        // Never longer than the cache's own time.
        let short = HostAddressCache(resolver: FakeResolver(["gone.example.com": nil]), ttl: 3, clock: { clock.now })
        short.lookUp("gone.example.com")
        clock.advance(2)
        short.lookUp("gone.example.com")
        clock.advance(2.5)
        #expect(short.check(host: "gone.example.com", address: address) == .lookupFailed)
        clock.advance(0.5)
        #expect(short.check(host: "gone.example.com", address: address) == .unknown)
    }

    // A failure is in a row with the last one only when its lookup started within 30 s of the
    // last one's expiry: one long after an outage counts 2 s, as a first failure does. A lookup
    // the resolver held for its whole timeout, longer than that, still goes on with the run.
    @Test func aFailureLongAfterTheLastCountsTwoSecondsAgain() {
        let clock = Clock()
        let address = ip("203.0.113.7")
        let cache = HostAddressCache(resolver: FakeResolver(["api.example.com": nil]), ttl: 30, clock: { clock.now })
        func failure(of cache: HostAddressCache, counts seconds: TimeInterval) {
            #expect(cache.lookUp("api.example.com").isEmpty)
            clock.advance(seconds - 0.5)
            #expect(cache.check(host: "api.example.com", address: address) == .lookupFailed, "\(seconds) s")
            clock.advance(0.5)
            #expect(cache.check(host: "api.example.com", address: address) == .unknown, "\(seconds) s")
        }
        for seconds: TimeInterval in [2, 4, 8] { failure(of: cache, counts: seconds) }
        clock.advance(30)
        failure(of: cache, counts: 16)
        clock.advance(30.5)
        failure(of: cache, counts: 2)
        // 45 s for each lookup to fail: the run goes on from when each lookup started.
        let slow = HostAddressCache(resolver: TimingOutResolver(clock, seconds: 45), ttl: 30, clock: { clock.now })
        for seconds: TimeInterval in [2, 4, 8, 16, 30] { failure(of: slow, counts: seconds) }
    }

    // A host whose last lookup failed less than 30 s ago may wait its turn for the next one:
    // until 1.0.8 a failure counted the whole 30 s, and every connection to the host that no DNS
    // answer named was dropped meanwhile. Any other host is looked up at once.
    @Test func aFailureIsRecentForThirtySecondsAfterItsLookup() {
        let resolver = FakeResolver(["api.example.com": nil, "www.example.com": ["203.0.113.7"]])
        let clock = Clock()
        let cache = HostAddressCache(resolver: resolver, ttl: 30, clock: { clock.now })
        #expect(!cache.failedRecently("api.example.com"))
        cache.lookUp("api.example.com")
        cache.lookUp("www.example.com")
        #expect(cache.failedRecently("api.example.com") && !cache.failedRecently("www.example.com"))
        // Past the failure's 2 s, and until 30 s after it.
        clock.advance(29.9)
        #expect(cache.checkOrRefresh(host: "api.example.com", address: ip("203.0.113.7")) == .unknown)
        #expect(cache.failedRecently("api.example.com"))
        clock.advance(0.1)
        #expect(!cache.failedRecently("api.example.com"))
        // Each failure from the end of its lookup; answers end it.
        cache.lookUp("api.example.com")
        clock.advance(10)
        #expect(cache.failedRecently("api.example.com"))
        resolver.set("api.example.com", ["203.0.113.8"])
        cache.lookUp("api.example.com")
        #expect(!cache.failedRecently("api.example.com"))
        let slow = HostAddressCache(resolver: TimingOutResolver(clock, seconds: 45), ttl: 30, clock: { clock.now })
        slow.lookUp("api.example.com")
        #expect(slow.failedRecently("api.example.com"))
    }

    @Test func staysBounded() {
        let clock = Clock()
        let cache = HostAddressCache(resolver: FakeResolver([:]), ttl: 30, limit: 2, clock: { clock.now })
        cache.store("a.example.com", [])
        cache.store("b.example.com", [])
        cache.store("c.example.com", [])
        let kept = ["a.example.com", "b.example.com", "c.example.com"].filter { cache.cached($0) != nil }
        #expect(kept.count <= 2 && kept.contains("c.example.com"))
    }

    @Test func systemResolverAnswersForLocalhost() {
        let answers = Set(SystemHostResolver().resolve("localhost") ?? [])
        #expect(answers.contains(ip("127.0.0.1")) || answers.contains(ip("::1")))
    }

    @Test func systemResolverKeepsTheScopeID() {
        // A numeric address resolves to itself, with no lookup; its zone becomes sin6_scope_id.
        #expect(SystemHostResolver().resolve("fe80::1%lo0") == [ip("fe80::1%lo0")])
        #expect(SystemHostResolver().resolve("fe80::1%lo0")?.first?.scope == if_nametoindex("lo0"))
    }
}

struct LookupWaitersTests {
    let app = AppIdentity.cdhash(String(repeating: "a", count: 40))
    let other = AppIdentity.cdhash(String(repeating: "b", count: 40))

    @Test func oneLookupPerHostAndABound() {
        var waiters = LookupWaiters<Int>(limit: 3, limitPerApp: 3)
        #expect(waiters.add(1, host: "a.example.com", app: app) == .startLookup)
        #expect(waiters.add(2, host: "a.example.com", app: app) == .waiting)
        #expect(waiters.add(3, host: "b.example.com", app: other) == .startLookup)
        #expect(waiters.add(4, host: "c.example.com", app: other) == .full)
        #expect(waiters.finish("a.example.com") == [1, 2])
        #expect(waiters.count == 1 && waiters.finish("a.example.com").isEmpty)
        #expect(waiters.add(5, host: "a.example.com", app: app) == .startLookup)
        #expect(Set(waiters.removeAll()) == [3, 5] && waiters.count == 0)
    }

    // One app's burst leaves places for the others, and its own places come back as lookups end.
    @Test func oneAppTakesAtMostItsShare() {
        var waiters = LookupWaiters<Int>(limit: 8)
        #expect(waiters.limitPerApp == 2)
        #expect(waiters.add(1, host: "a.example.com", app: app) == .startLookup)
        #expect(waiters.add(2, host: "b.example.com", app: app) == .startLookup)
        #expect(waiters.add(3, host: "a.example.com", app: app) == .appFull)
        #expect(waiters.add(4, host: "a.example.com", app: other) == .waiting)
        #expect(waiters.add(5, host: "c.example.com", app: nil) == .startLookup)
        #expect(waiters.add(6, host: "c.example.com", app: nil) == .waiting)
        #expect(waiters.add(7, host: "c.example.com", app: nil) == .appFull)
        #expect(waiters.finish("a.example.com") == [1, 4])
        #expect(waiters.waitingFor(app) == 1 && waiters.waitingFor(other) == 0 && waiters.count == 3)
        #expect(waiters.add(8, host: "d.example.com", app: app) == .startLookup)
        #expect(waiters.add(9, host: "d.example.com", app: app) == .appFull)
        #expect(Set(waiters.removeAll()) == [2, 5, 6, 8])
        #expect(waiters.waitingFor(app) == 0 && waiters.waitingFor(nil) == 0)
    }

    // Several apps, each under its share, fill the table; a refused flow changes no count, and a
    // lookup that ends after removeAll finds nothing.
    @Test func theTotalBoundHoldsAcrossApps() {
        var waiters = LookupWaiters<Int>(limit: 4, limitPerApp: 2)
        #expect(waiters.add(1, host: "a.example.com", app: app) == .startLookup)
        #expect(waiters.add(2, host: "a.example.com", app: app) == .waiting)
        #expect(waiters.add(3, host: "b.example.com", app: other) == .startLookup)
        #expect(waiters.add(4, host: "b.example.com", app: other) == .waiting)
        #expect(waiters.add(5, host: "c.example.com", app: nil) == .full)
        #expect(waiters.add(6, host: "c.example.com", app: app) == .full)
        #expect(waiters.count == 4 && waiters.waitingFor(app) == 2 && waiters.waitingFor(nil) == 0)
        #expect(waiters.removeAll().count == 4)
        #expect(waiters.finish("a.example.com").isEmpty && waiters.count == 0 && waiters.waitingFor(app) == 0)
        #expect(waiters.add(7, host: "a.example.com", app: app) == .startLookup)
    }

    // Each lookup holds a thread while the resolver takes its time: at most lookupLimit run at
    // once when a host that failed recently would start one, and its lookup waits its turn, the
    // oldest first, as lookups end.
    @Test func atMostTheLimitOfLookupsRunAtOnce() {
        var waiters = LookupWaiters<Int>(limit: 16, limitPerApp: 16, lookupLimit: 2)
        #expect(LookupWaiters<Int>().lookupLimit == 16)
        #expect(waiters.add(1, host: "a.example.com", app: app, failedRecently: true) == .startLookup)
        #expect(waiters.add(2, host: "b.example.com", app: app, failedRecently: true) == .startLookup)
        #expect(waiters.add(3, host: "c.example.com", app: other, failedRecently: true) == .queued)
        #expect(waiters.add(4, host: "c.example.com", app: app, failedRecently: true) == .waiting)
        #expect(waiters.add(5, host: "d.example.com", app: nil, failedRecently: true) == .queued)
        #expect(waiters.add(6, host: "a.example.com", app: nil, failedRecently: true) == .waiting)
        #expect(waiters.running == 2 && waiters.count == 6 && waiters.nextLookup() == nil)
        // A lookup ends: the host that waited longest starts, and the next waits for another end.
        #expect(waiters.finish("a.example.com") == [1, 6])
        #expect(waiters.nextLookup() == "c.example.com" && waiters.nextLookup() == nil && waiters.running == 2)
        #expect(waiters.add(7, host: "e.example.com", app: other, failedRecently: true) == .queued)
        #expect(waiters.finish("b.example.com") == [2])
        #expect(waiters.nextLookup() == "d.example.com" && waiters.nextLookup() == nil)
        #expect(waiters.finish("c.example.com") == [3, 4])
        #expect(waiters.nextLookup() == "e.example.com")
        #expect(waiters.finish("d.example.com") == [5] && waiters.finish("e.example.com") == [7])
        #expect(waiters.nextLookup() == nil && waiters.running == 0 && waiters.count == 0)
        #expect(waiters.add(8, host: "f.example.com", app: app, failedRecently: true) == .startLookup)
    }

    // A host with no recent failure is looked up at once, however many lookups run, as in 1.0.7:
    // a resolver that hangs for some hosts (a split-DNS domain whose server is gone, about 30 s a
    // lookup) kept the lookups of the others waiting behind them, until their flows filled the
    // places and connections a rule allowed were dropped as lookup_capacity. Its lookup counts
    // with the rest, so a host that failed recently waits until fewer than the limit run.
    @Test func aHostWithNoRecentFailureIsLookedUpAtOnce() {
        var waiters = LookupWaiters<Int>(limit: 16, limitPerApp: 16, lookupLimit: 2)
        #expect(waiters.add(1, host: "a.corp.example", app: app, failedRecently: true) == .startLookup)
        #expect(waiters.add(2, host: "b.corp.example", app: app, failedRecently: true) == .startLookup)
        #expect(waiters.add(3, host: "c.corp.example", app: app, failedRecently: true) == .queued)
        #expect(waiters.add(4, host: "api.example.com", app: other) == .startLookup)
        #expect(waiters.add(5, host: "api.example.com", app: other) == .waiting)
        #expect(waiters.add(6, host: "cdn.example.com", app: nil, failedRecently: false) == .startLookup)
        #expect(waiters.running == 4 && waiters.nextLookup() == nil)
        // Answered at once, while the lookups of a and b hang: c still waits its turn.
        #expect(waiters.finish("api.example.com") == [4, 5] && waiters.finish("cdn.example.com") == [6])
        #expect(waiters.nextLookup() == nil && waiters.running == 2)
        #expect(waiters.add(7, host: "api.example.com", app: other) == .startLookup)
        #expect(waiters.finish("api.example.com") == [7] && waiters.nextLookup() == nil)
        // A hung lookup ends: c's turn.
        #expect(waiters.finish("a.corp.example") == [1])
        #expect(waiters.nextLookup() == "c.corp.example" && waiters.running == 2)
        #expect(waiters.finish("b.corp.example") == [2] && waiters.finish("c.corp.example") == [3])
        #expect(waiters.running == 0 && waiters.count == 0)
    }

    // A flow waits at most turnWait for a lookup that waits its turn, from when it began to wait;
    // then the maintenance timer drops it as lookup_timeout. Flows whose lookup has started wait
    // for its end. Every flow comes back once, by expire or by finish, and nothing is left.
    @Test func flowsWaitingTheirTurnAreDroppedAfterTenSeconds() {
        #expect(LookupWaiters<Int>.turnWait == 10)
        var waiters = LookupWaiters<Int>(limit: 16, limitPerApp: 16, lookupLimit: 1)
        #expect(waiters.add(1, host: "a.corp.example", app: app, failedRecently: true, now: 100) == .startLookup)
        #expect(waiters.add(2, host: "b.corp.example", app: app, failedRecently: true, now: 100) == .queued)
        #expect(waiters.add(3, host: "c.corp.example", app: other, failedRecently: true, now: 103) == .queued)
        #expect(waiters.add(4, host: "b.corp.example", app: other, failedRecently: true, now: 106) == .waiting)
        #expect(waiters.add(5, host: "a.corp.example", app: other, failedRecently: true, now: 100) == .waiting)
        #expect(waiters.expire(now: 109.9).isEmpty)
        // Each flow from its own start: b's first goes, its second keeps b's turn.
        #expect(waiters.expire(now: 110) == [2])
        #expect(waiters.count == 4 && waiters.waitingFor(app) == 1 && waiters.waitingFor(other) == 3)
        // c's only flow goes, and its turn with it.
        #expect(waiters.expire(now: 113) == [3])
        #expect(waiters.expire(now: 115).isEmpty && waiters.count == 3)
        // a's lookup ran all along, and its flows were never dropped.
        #expect(waiters.finish("a.corp.example") == [1, 5])
        #expect(waiters.nextLookup() == "b.corp.example" && waiters.nextLookup() == nil)
        // b's lookup has started: its flow waits for it, past turnWait.
        #expect(waiters.expire(now: 200).isEmpty)
        #expect(waiters.finish("b.corp.example") == [4])
        #expect(waiters.count == 0 && waiters.running == 0 && waiters.waitingFor(app) == 0 && waiters.waitingFor(other) == 0)
        // c, queued again, has one turn, in order.
        #expect(waiters.add(6, host: "a.corp.example", app: app, failedRecently: true, now: 300) == .startLookup)
        #expect(waiters.add(7, host: "c.corp.example", app: app, failedRecently: true, now: 300) == .queued)
        #expect(waiters.add(8, host: "d.corp.example", app: app, failedRecently: true, now: 301) == .queued)
        #expect(waiters.finish("a.corp.example") == [6])
        #expect(waiters.nextLookup() == "c.corp.example" && waiters.nextLookup() == nil)
        #expect(waiters.finish("c.corp.example") == [7])
        #expect(waiters.nextLookup() == "d.corp.example" && waiters.nextLookup() == nil)
        #expect(waiters.finish("d.corp.example") == [8] && waiters.nextLookup() == nil)
        #expect(waiters.running == 0 && waiters.count == 0)
        // Many flows of several hosts waiting their turn, all past it: each comes back once.
        #expect(waiters.add(0, host: "hung.corp.example", app: nil, failedRecently: true, now: 400) == .startLookup)
        for index in 1...12 {
            #expect(waiters.add(index, host: "h\(index % 5).corp.example", app: index % 2 == 0 ? app : other,
                                failedRecently: true, now: 400 + Double(index) / 10) == (index <= 5 ? .queued : .waiting))
        }
        #expect(waiters.expire(now: 410.5).sorted() == [1, 2, 3, 4, 5])
        #expect(waiters.expire(now: 412).sorted() == Array(6...12))
        #expect(waiters.count == 1 && waiters.waitingFor(app) == 0 && waiters.waitingFor(other) == 0)
        #expect(waiters.finish("hung.corp.example") == [0] && waiters.nextLookup() == nil && waiters.count == 0)
    }

    // removeAll drops the flows that wait their turn with the rest, and the lookups still running
    // count until they end: the bound holds across a configuration change.
    @Test func lookupsThatRunCountUntilTheyEndAfterRemoveAll() {
        var waiters = LookupWaiters<Int>(limit: 16, limitPerApp: 16, lookupLimit: 1)
        #expect(waiters.add(1, host: "a.example.com", app: app) == .startLookup)
        #expect(waiters.add(2, host: "b.example.com", app: app, failedRecently: true) == .queued)
        #expect(Set(waiters.removeAll()) == [1, 2] && waiters.running == 1)
        #expect(waiters.add(3, host: "c.example.com", app: app, failedRecently: true) == .queued)
        #expect(waiters.finish("a.example.com").isEmpty && waiters.running == 0)
        // b went with removeAll: c is next.
        #expect(waiters.nextLookup() == "c.example.com" && waiters.nextLookup() == nil)
        // c's lookup runs on across another removeAll. A flow for c then waits its turn; that
        // lookup's answers serve it, and its own turn is passed over.
        #expect(waiters.removeAll() == [3])
        #expect(waiters.add(4, host: "c.example.com", app: app, failedRecently: true) == .queued)
        #expect(waiters.finish("c.example.com") == [4] && waiters.nextLookup() == nil && waiters.running == 0)
        #expect(waiters.add(5, host: "c.example.com", app: app) == .startLookup)
        #expect(waiters.finish("c.example.com") == [5] && waiters.running == 0)
        // An unmatched end never counts below none.
        #expect(waiters.finish("z.example.com").isEmpty && waiters.running == 0)
    }
}
