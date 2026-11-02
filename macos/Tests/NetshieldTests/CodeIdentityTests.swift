import Darwin
import Foundation
import Testing
@testable import NetshieldCore

// From blackice macos/Tests/IdentityCacheTests.swift at 45a7870. The part that replaces the
// test executable on disk did not come over: under `swift test` the running process is the
// test runner, which must not be replaced.

private func ownAuditToken() -> Data? {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return withUnsafeBytes(of: &token) { Data($0) }
}

struct CodeIdentityTests {
    @Test func cacheStaysBounded() {
        let small = IdentityCache(limit: 2)
        for byte in UInt8(1)...3 { small.store(Data([byte]), .adHoc) }
        #expect(small.count <= 2)
    }

    @Test func missingOrShortTokenIsUnresolved() {
        #expect(CodeIdentity.resolve(auditToken: nil) == .unresolved)
        #expect(CodeIdentity.resolve(auditToken: Data([1, 2, 3])) == .unresolved)
        #expect(CodeIdentity.resolve(auditToken: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size + 1)) == .unresolved)
    }

    @Test func ownProcessResolvesByAuditToken() throws {
        let token = try #require(ownAuditToken())
        CodeIdentity.cache.remove(token)
        let byToken = CodeIdentity.resolve(auditToken: token)
        #expect(byToken == CodeIdentity.currentResolution())
        switch byToken {
        case .verified, .adHoc: #expect(CodeIdentity.cache.read(token) == byToken)
        case .unresolved, .invalidSignature: #expect(CodeIdentity.cache.read(token) == nil)
        }
        CodeIdentity.cache.remove(token)
    }
}
