import Darwin
import Foundation
import Security
import Testing
@testable import BlackiceCore

// From blackice-poc macos/Tests/IdentityCacheTests.swift at 45a7870. The part that replaces the
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
        for byte in UInt8(1)...3 { small.store(Data([byte]), .adHoc(cdhash: String(repeating: "a", count: 40))) }
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

    @Test func theRequirementNamesEachKindOfSignature() {
        let apple = CodeIdentity.requirementText(signingID: "com.apple.curl", teamID: nil)
        let team = CodeIdentity.requirementText(signingID: "com.example.tool", teamID: "ABCDE12345")
        #expect(apple == #"anchor apple and identifier "com.apple.curl""#)
        #expect(team == #"identifier "com.example.tool" and (anchor apple or anchor apple generic and "#
            + #"(certificate leaf[subject.OU] = "ABCDE12345" or certificate leaf[field.1.2.840.113635.100.6.1.9] exists))"#)
        #expect(CodeIdentity.requirement(apple) != nil)
        #expect(CodeIdentity.requirement(team) != nil)
    }

    @Test func applePlatformCodeHasNoTeam() {
        #expect(CodeIdentity.identity(atPath: "/usr/bin/curl") == SigningIdentity(signingID: "com.apple.curl", teamID: nil))
    }

    /// Apple signs the tools of the Command Line Tools and Xcode itself, and their code directory
    /// carries Team ID 59GAB85EFG, which the leaf's OU does not. Skipped where neither is installed.
    @Test func appleDeveloperToolsKeepTheirTeam() throws {
        let candidates = ["/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-https",
                          "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let identity = try #require(CodeIdentity.identity(atPath: path))
        #expect(identity.teamID == "59GAB85EFG")
        #expect(identity.signingID.hasPrefix("com.apple."))
    }

    /// The same for the running code, the check the filter makes for each flow: git waits on its
    /// input while it is resolved.
    @Test func aRunningAppleDeveloperToolIsVerifiedWithItsTeam() throws {
        let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: path)
        git.arguments = ["hash-object", "--stdin"]
        let input = Pipe()
        git.standardInput = input
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        defer {
            try? input.fileHandleForWriting.close()
            git.waitUntilExit()
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: git.processIdentifier] as CFDictionary
        #expect(SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess)
        let resolution = CodeIdentity.resolution(of: try #require(code))
        #expect(resolution.verifiedIdentity?.teamID == "59GAB85EFG")
    }

    /// Mac App Store apps are signed by Apple with the developer's Team ID in the code directory.
    /// Skipped on a Mac with none.
    @Test func macAppStoreAppsKeepTheirTeam() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        guard let name = names.sorted().first(where: {
            $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: "/Applications/\($0)/Contents/_MASReceipt")
        }) else { return }
        let identity = try #require(CodeIdentity.identity(atPath: "/Applications/" + name))
        #expect(identity.teamID.map(validTeamID) == true)
    }
}
