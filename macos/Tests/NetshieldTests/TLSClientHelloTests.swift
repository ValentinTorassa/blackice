import Foundation
import Testing
@testable import NetshieldCore

// Vectors from blackice macos/Tests/SecurityRegressions.swift at 45a7870.

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

/// A TLS 1.3 ClientHello with supported_versions and, optionally, SNI. Also used by FilterPolicyTests.
func clientHello(_ host: String?, extra: [UInt8] = [], duplicateSNI: Bool = false) -> Data {
    var extensions: [UInt8] = [0, 43, 0, 3, 2, 3, 4]
    if let host {
        let name = Array(host.utf8)
        let sni: [UInt8] = [0, 0] + word(name.count + 5) + word(name.count + 3) + [0] + word(name.count) + name
        extensions += sni
        if duplicateSNI { extensions += sni }
    }
    extensions += extra
    var body: [UInt8] = [3, 3] + Array(repeating: 0xab, count: 32)
    body += [0, 0, 2, 0x13, 1, 1, 0]
    body += word(extensions.count) + extensions
    return Data([0x16, 3, 1] + word(body.count + 4) + [1, 0] + word(body.count) + body)
}

private let echExtension: [UInt8] = [0xfe, 0x0d, 0, 4, 0x42, 0x87, 0x19, 0xff]

struct TLSClientHelloTests {
    let hello = clientHello("api.example.com")

    @Test func readsServerName() {
        #expect(TLSClientHello.inspect(hello) == .serverName("api.example.com"))
        #expect(TLSClientHello.inspect(clientHello("API.Example.COM.")) == .serverName("api.example.com"))
    }

    @Test func missingServerNameAndPlaintext() {
        #expect(TLSClientHello.inspect(clientHello(nil)) == .deny("sni_missing"))
        #expect(TLSClientHello.inspect(Data("GET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n".utf8)) == .deny("not_tls"))
    }

    @Test func everyTruncationWaitsForMore() {
        for end in 0..<hello.count {
            guard case .needMore = TLSClientHello.inspect(hello.prefix(end)) else {
                Issue.record("a ClientHello cut at \(end) bytes must wait for more")
                return
            }
        }
    }

    @Test func fragmentsAndPrefixes() {
        var fragmented = TLSInspection(expectedHost: "api.example.com")
        #expect(fragmented.receive(hello.prefix(3), offset: 0) == .needMore(5))
        #expect(fragmented.receive(hello.prefix(5), offset: 0) == .needMore(hello.count))
        #expect(fragmented.receive(hello.dropFirst(5), offset: 5) == .serverName("api.example.com"))

        var mismatch = TLSInspection(expectedHost: "api.example.com")
        #expect(mismatch.receive(clientHello("evil.example.com"), offset: 0) == .deny("sni_mismatch"))

        var gap = TLSInspection(expectedHost: "api.example.com")
        #expect(gap.receive(hello, offset: 1) == .deny("tls_unparsed"))

        var changedPrefix = TLSInspection(expectedHost: "api.example.com")
        _ = changedPrefix.receive(hello.prefix(5), offset: 0)
        var changed = hello
        changed[2] = 3
        #expect(changedPrefix.receive(changed, offset: 0) == .deny("tls_unparsed"))
    }

    @Test func encryptedClientHelloIsOnlyNoted() {
        let echHello = clientHello("api.example.com", extra: echExtension)
        #expect(TLSClientHello.inspect(echHello) == .serverName("api.example.com", echPresent: true))
        var matching = TLSInspection(expectedHost: "api.example.com")
        #expect(matching.receive(echHello, offset: 0) == .serverName("api.example.com", echPresent: true))
        var wrong = TLSInspection(expectedHost: "other.example.com")
        #expect(wrong.receive(echHello, offset: 0) == .deny("sni_mismatch"))
        #expect(matching.echPresent && wrong.echPresent)
        #expect(TLSClientHello.inspect(clientHello(nil, extra: echExtension)) == .deny("sni_missing"))
        #expect(TLSClientHello.inspect(clientHello("api.example.com", extra: echExtension + echExtension)) == .deny("tls_unparsed"))
    }

    @Test(arguments: ["", "evil\0.example.com", "éxample.com", "127.0.0.1", "bad..example.com"])
    func refusesInvalidServerNames(_ name: String) {
        #expect(TLSClientHello.inspect(clientHello(name)) == .deny("tls_unparsed"))
    }

    @Test func malformedRecords() {
        #expect(TLSClientHello.inspect(clientHello("api.example.com", duplicateSNI: true)) == .deny("tls_unparsed"))
        #expect(TLSClientHello.inspect(Data([0x16, 3, 1, 0x40, 0])) == .deny("tls_unparsed"))
        #expect(TLSClientHello.inspect(Data(repeating: 0x16, count: TLSClientHello.maximumBytes + 1)) == .deny("tls_unparsed"))
        var crossRecord = hello
        crossRecord[8] += 1
        #expect(TLSClientHello.inspect(crossRecord) == .deny("tls_unparsed"))
        var trailing = hello
        trailing[hello.count - 1] = 0
        #expect(TLSClientHello.inspect(trailing) == .deny("tls_unparsed"))
    }
}
