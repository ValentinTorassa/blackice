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

/// The audit token of a child process, through its task name port.
private func auditToken(of pid: pid_t) -> Data? {
    var name: mach_port_t = 0
    guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, name) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return withUnsafeBytes(of: &token) { Data($0) }
}

struct CodeIdentityTests {
    /// An app updated while it runs: its program file is removed, and Security no longer finds the
    /// process. The identity checked while the file was there stays for that process image, also in
    /// a cache restored from disk in the same boot, and goes when the process exits.
    @Test func aRunningProcessKeepsItsIdentityWhenItsFileIsRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-removed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("sleep")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy.path)
        let sleep = Process()
        sleep.executableURL = copy
        sleep.arguments = ["30"]
        try sleep.run()
        defer { if sleep.isRunning { sleep.terminate(); sleep.waitUntilExit() } }
        let token = try #require(auditToken(of: sleep.processIdentifier))

        let cache = IdentityCache()
        let identity = IdentityResolution.verified(SigningIdentity(signingID: "com.apple.sleep", teamID: nil))
        #expect(CodeIdentity.resolve(auditToken: token, cache: cache) == identity)
        let boot = try #require(CodeIdentity.bootSession())
        let stored = try #require(cache.encoded(boot: boot, keep: CodeIdentity.kernelReportsValid))

        let cdhash = try #require(CodeIdentity.kernelCDHash(auditToken: token))
        try FileManager.default.removeItem(at: copy)
        #expect(CodeIdentity.kernelReportsValid(auditToken: token))
        #expect(CodeIdentity.resolve(auditToken: token, cache: cache) == identity)
        // A new run of the extension: with nothing cached, Security cannot read the file, so the
        // process is named by the kernel's cdhash, as when the file is under ~/Documents; then
        // the stored cache brings the signing identity back.
        let fresh = IdentityCache()
        #expect(CodeIdentity.resolve(auditToken: token, cache: fresh) == .adHoc(cdhash: cdhash))
        #expect(fresh.count == 0)
        #expect(fresh.restore(stored, boot: boot) == 1)
        #expect(CodeIdentity.resolve(auditToken: token, cache: fresh) == identity)

        sleep.terminate()
        sleep.waitUntilExit()
        #expect(!CodeIdentity.kernelReportsValid(auditToken: token))
        #expect(CodeIdentity.kernelCDHash(auditToken: token) == nil)
        #expect(CodeIdentity.resolve(auditToken: token, cache: cache) == .unresolved)
        #expect(CodeIdentity.resolve(auditToken: token, cache: IdentityCache()) == .unresolved)
    }

    /// The kernel's cdhash for a process is the one Security reads from its signature, and its path
    /// is the process's own executable.
    @Test func theKernelNamesTheCodeItLoaded() throws {
        let token = try #require(ownAuditToken())
        var code: SecCode?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        var information: CFDictionary?
        #expect(SecCodeCopySigningInformation(unsafeBitCast(try #require(code), to: SecStaticCode.self),
                                              SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let unique = try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        #expect(CodeIdentity.kernelCDHash(auditToken: token) == unique.map { String(format: "%02x", $0) }.joined())

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        #expect(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let own = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(CodeIdentity.kernelPath(auditToken: token) == own)
        #expect(CodeIdentity.kernelPath(auditToken: Data(count: 3)) == nil)
        #expect(CodeIdentity.kernelCDHash(auditToken: Data(count: 3)) == nil)
    }

    /// Without a readable file, only valid code with a well-formed cdhash gets a name, and never a
    /// signing identity.
    @Test func theKernelFallbackNamesOnlyValidCodeByItsCDHash() {
        let token = Data(count: MemoryLayout<audit_token_t>.size)
        let hash = String(repeating: "ab", count: 20)
        #expect(CodeIdentity.kernelResolution(auditToken: token, valid: { _ in true }, cdhash: { _ in hash }) == .adHoc(cdhash: hash))
        #expect(CodeIdentity.kernelResolution(auditToken: token, valid: { _ in false }, cdhash: { _ in hash }) == .unresolved)
        #expect(CodeIdentity.kernelResolution(auditToken: token, valid: { _ in true }, cdhash: { _ in nil }) == .unresolved)
        #expect(CodeIdentity.kernelResolution(auditToken: token, valid: { _ in true }, cdhash: { _ in "AB" + hash.dropFirst(2) }) == .unresolved)
    }

    /// A stored cache comes back only in the boot it was written in, and only with entries a
    /// resolution could have made.
    @Test func storedIdentitiesComeBackOnlyInTheSameBoot() throws {
        let size = MemoryLayout<audit_token_t>.size
        let signed = Data(repeating: 1, count: size), adHoc = Data(repeating: 2, count: size), gone = Data(repeating: 3, count: size)
        let cache = IdentityCache()
        cache.store(signed, .verified(SigningIdentity(signingID: "com.example.agent", teamID: "ABCDE12345")))
        cache.store(adHoc, .adHoc(cdhash: String(repeating: "a", count: 40)))
        cache.store(gone, .verified(SigningIdentity(signingID: "com.example.gone", teamID: nil)))
        let data = try #require(cache.encoded(boot: "boot-1", keep: { $0 != gone }))

        let again = IdentityCache()
        #expect(again.restore(data, boot: "boot-2") == 0)
        #expect(again.restore(Data("not json".utf8), boot: "boot-1") == 0)
        #expect(again.restore(data, boot: "boot-1") == 2)
        #expect(again.read(signed) == cache.read(signed))
        #expect(again.read(adHoc) == cache.read(adHoc))
        #expect(again.read(gone) == nil)

        let forged = try JSONEncoder().encode(StoredIdentities(boot: "boot-1", entries: [
            .init(token: Data(repeating: 4, count: size), signingID: "bad id with spaces", teamID: nil, cdhash: nil),
            .init(token: Data(repeating: 5, count: size), signingID: "com.example.x", teamID: "short", cdhash: nil),
            .init(token: Data(repeating: 6, count: size), signingID: "com.example.y", teamID: nil, cdhash: String(repeating: "b", count: 40)),
            .init(token: Data([7]), signingID: "com.example.z", teamID: nil, cdhash: nil),
        ]))
        #expect(IdentityCache().restore(forged, boot: "boot-1") == 0)
    }

    @Test func cacheStaysBounded() {
        let small = IdentityCache(limit: 2)
        for byte in UInt8(1)...3 { small.store(Data([byte]), .adHoc(cdhash: String(repeating: "a", count: 40))) }
        #expect(small.count <= 2)
    }

    /// A full cache forgets the processes that ended, and keeps the one still running: a
    /// long-running app needs its entry once an update removes its program file.
    @Test func aFullCacheKeepsTheProcessesThatStillRun() throws {
        let alive = Data([1]), cdhash = IdentityResolution.adHoc(cdhash: String(repeating: "a", count: 40))
        let cache = IdentityCache(limit: 3, running: { $0 == alive })
        for byte in UInt8(1)...4 { cache.store(Data([byte]), cdhash) }
        #expect(cache.count == 2)
        #expect(cache.read(alive) == cdhash)
        #expect(cache.read(Data([4])) == cdhash)
        #expect(cache.read(Data([2])) == nil)

        // The real check: this test runner runs, a made-up token names no process.
        let own = try #require(ownAuditToken())
        let real = IdentityCache(limit: 2)
        real.store(own, cdhash)
        real.store(Data(repeating: 9, count: own.count), cdhash)
        real.store(Data(repeating: 8, count: own.count), cdhash)
        #expect(real.read(own) == cdhash)
        #expect(real.count == 2)
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
    @Test func macAppStoreAppsKeepTheirTeam() async throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        guard let name = names.sorted().first(where: {
            $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: "/Applications/\($0)/Contents/_MASReceipt")
        }) else { return }
        // Checking a whole app's signature takes seconds.
        let identity = try #require(await offThePool { CodeIdentity.identity(atPath: "/Applications/" + name) })
        #expect(identity.teamID.map(validTeamID) == true)
    }
}
