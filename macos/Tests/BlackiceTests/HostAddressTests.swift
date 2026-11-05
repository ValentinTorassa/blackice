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
    @Test func oneLookupPerHostAndABound() {
        var waiters = LookupWaiters<Int>(limit: 3)
        #expect(waiters.add(1, host: "a.example.com") == .startLookup)
        #expect(waiters.add(2, host: "a.example.com") == .waiting)
        #expect(waiters.add(3, host: "b.example.com") == .startLookup)
        #expect(waiters.add(4, host: "c.example.com") == .full)
        #expect(waiters.finish("a.example.com") == [1, 2])
        #expect(waiters.count == 1 && waiters.finish("a.example.com").isEmpty)
        #expect(waiters.add(5, host: "a.example.com") == .startLookup)
        #expect(Set(waiters.removeAll()) == [3, 5] && waiters.count == 0)
    }
}
