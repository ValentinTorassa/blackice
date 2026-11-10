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

    func set(_ host: String, _ answers: [String]) {
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

    @Test func failedLookupMismatchesEverything() {
        let cache = HostAddressCache(resolver: FakeResolver(["gone.example.com": nil]))
        #expect(cache.lookUp("gone.example.com").isEmpty)
        #expect(cache.check(host: "gone.example.com", address: ip("203.0.113.7")) == .mismatch)
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

    @Test func aFailedLookupOrAnUncheckableAddressIsNotLookedUpAgain() {
        let clock = Clock()
        let cache = HostAddressCache(resolver: FakeResolver(["gone.example.com": nil, "printer.local": ["fe80::1%1"]]),
                                     ttl: 30, clock: { clock.now })
        cache.lookUp("gone.example.com")
        cache.lookUp("printer.local")
        clock.advance(10)
        #expect(cache.checkOrRefresh(host: "gone.example.com", address: ip("203.0.113.7")) == .mismatch)
        #expect(cache.checkOrRefresh(host: "printer.local", address: ip("fe80::1")) == .mismatch)
        #expect(cache.checkOrRefresh(host: "printer.local", address: nil) == .mismatch)
        // Expired answers are unknown, as with check.
        clock.advance(20)
        #expect(cache.checkOrRefresh(host: "gone.example.com", address: ip("203.0.113.7")) == .unknown)
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
}
