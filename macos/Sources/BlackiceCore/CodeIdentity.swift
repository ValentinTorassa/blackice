// Ported from blackice-poc macos/Shared/CodeIdentity.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/Shared/CodeIdentity.swift).
// Changes: public API, IdentityCache marked @unchecked Sendable (all state is behind its lock);
// ad hoc code comes back with its cdhash, and path(auditToken:) is new (phase 2).
import Darwin
import Foundation
import Security

/// Positive identities of running process images, keyed by the full audit
/// token. The token carries the PID version, which changes on exec, so one key
/// never names two images. Bounded: when full it forgets the processes that ended, and starts over
/// only if every entry still runs.
public final class IdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data: IdentityResolution] = [:]
    private let limit: Int
    private let running: (Data) -> Bool
    private var changeCount = 0

    /// `running` says whether the process a token names still runs.
    public init(limit: Int = 4096, running: @escaping (Data) -> Bool = CodeIdentity.kernelReportsValid) {
        self.limit = limit
        self.running = running
    }

    public func read(_ token: Data) -> IdentityResolution? {
        lock.lock(); defer { lock.unlock() }
        return entries[token]
    }

    public func store(_ token: Data, _ resolution: IdentityResolution) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= limit {
            // Emptying it all would also drop a long-running app's entry, which it needs once an
            // update removes its program file (see CodeIdentity.resolve).
            entries = entries.filter { running($0.key) }
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        }
        entries[token] = resolution
        changeCount += 1
    }

    public func remove(_ token: Data) {
        lock.lock(); defer { lock.unlock() }
        if entries.removeValue(forKey: token) != nil { changeCount += 1 }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Goes up with each change, so that a caller saves only when there is something new.
    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return changeCount
    }

    /// The verified and ad hoc entries whose token `keep` accepts, for the extension's next run in
    /// the same boot. Audit tokens are unique within a boot only: after a restart a new process can
    /// carry a token that an old one had, so `restore` takes entries only from the boot `boot` names.
    public func encoded(boot: String, keep: (Data) -> Bool = { _ in true }) -> Data? {
        lock.lock()
        let current = entries
        lock.unlock()
        let stored = current.compactMap { token, resolution -> StoredIdentities.Entry? in
            guard keep(token) else { return nil }
            switch resolution {
            case .verified(let identity):
                return .init(token: token, signingID: identity.signingID, teamID: identity.teamID, cdhash: nil)
            case .adHoc(let cdhash):
                return .init(token: token, signingID: nil, teamID: nil, cdhash: cdhash)
            case .unresolved, .invalidSignature:
                return nil
            }
        }
        return try? JSONEncoder().encode(StoredIdentities(boot: boot, entries: stored))
    }

    /// Adds the entries `encoded` wrote in this boot, as far as the limit allows; data from another
    /// boot, or that does not parse, adds nothing. Returns how many it added.
    @discardableResult
    public func restore(_ data: Data, boot: String) -> Int {
        guard let stored = try? JSONDecoder().decode(StoredIdentities.self, from: data), stored.boot == boot else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var added = 0
        for entry in stored.entries where entries.count < limit && entries[entry.token] == nil {
            guard entry.token.count == MemoryLayout<audit_token_t>.size, let resolution = entry.resolution else { continue }
            entries[entry.token] = resolution
            added += 1
        }
        return added
    }
}

/// IdentityCache's entries on disk.
struct StoredIdentities: Codable {
    let boot: String
    let entries: [Entry]

    struct Entry: Codable {
        let token: Data
        let signingID: String?
        let teamID: String?
        let cdhash: String?

        /// nil for an entry no resolution could have produced.
        var resolution: IdentityResolution? {
            if let cdhash {
                return signingID == nil && teamID == nil && validCDHash(cdhash) ? .adHoc(cdhash: cdhash) : nil
            }
            guard let signingID, validSigningID(signingID) else { return nil }
            if let teamID, !validTeamID(teamID) { return nil }
            return .verified(SigningIdentity(signingID: signingID, teamID: teamID))
        }
    }
}

/// csops(2) with an audit token, from the kernel; not in the SDK's headers.
@_silgen_name("csops_audittoken")
private func csops_audittoken(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int,
                              _ token: UnsafeMutablePointer<audit_token_t>?) -> Int32

public enum CodeIdentity {
    public static let cache = IdentityCache()

    static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The requirement code must satisfy to be known by this signing identifier and Team ID, running
    /// or on disk. Without a Team ID, only Apple platform code qualifies. With one, three kinds of
    /// signature do:
    /// - Developer ID and Apple Development certificates, which name the team in the leaf's OU;
    /// - Apple's own ("Software Signing", `anchor apple`) on the tools the Command Line Tools and
    ///   Xcode install, such as git, git-remote-https, python3 and notarytool, which carry Team ID
    ///   59GAB85EFG;
    /// - the Mac App Store's ("Apple Mac OS Application Signing", leaf field
    ///   1.2.840.113635.100.6.1.9), which carries the developer's Team ID.
    /// In the last two the leaf's OU is not the Team ID, but Apple's signature covers the code
    /// directory, and the Team ID in it. Checking the OU alone made both invalid_signature, and in ask
    /// and block-all their connections were dropped without asking: git over HTTPS, notarytool and
    /// Mac App Store apps among them.
    static func requirementText(signingID: String, teamID: String?) -> String {
        guard let teamID else { return "anchor apple and identifier \"\(signingID)\"" }
        return "identifier \"\(signingID)\" and (anchor apple or anchor apple generic and " +
            "(certificate leaf[subject.OU] = \"\(teamID)\" or certificate leaf[field.1.2.840.113635.100.6.1.9] exists))"
    }

    /// The audit token includes the process generation. No PID-only lookups,
    /// paths, claimed bundle IDs or parent scans.
    ///
    /// A verified or ad hoc result is kept for that process image. Full
    /// validation also checks the files on disk, so without the cache an app
    /// that updates itself while running (or whose bundle changes) would lose
    /// its identity until it restarts: denied even under unmatched=allow, and a
    /// bound app would stop matching its binding. A cached result is used only
    /// while the kernel still reports the running code as valid, so code that
    /// becomes invalid falls back to full validation and is denied.
    public static func resolve(auditToken: Data?, cache: IdentityCache = CodeIdentity.cache) -> IdentityResolution {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return .unresolved }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            // Security finds no guest when it cannot read the program file. That happens to a
            // process whose file was removed since it started, as when Homebrew upgrades an app
            // that is running: on 5 November 2026 Claude Code's connections became
            // unknown_identity the minute Homebrew removed its old version. The identity cached
            // for this process image, checked while the file was there, stays while the kernel
            // still reports the code valid.
            if let cached = cache.read(auditToken), kernelReportsValid(auditToken: auditToken) { return cached }
            // It also happens to every program under a folder macOS keeps the extension from
            // reading: ~/Documents, ~/Desktop, ~/Downloads, iCloud Drive, removable and network
            // volumes. On 6 November 2026 the same gh binary connected from /opt/homebrew and was
            // dropped as unknown_identity from ~/Documents. The kernel still knows the code it
            // loaded, so the process is named by that cdhash, as ad hoc code is.
            return kernelResolution(auditToken: auditToken)
        }
        if let cached = cache.read(auditToken) {
            if runningCodeIsValid(code) { return cached }
            cache.remove(auditToken)
        }
        let result = resolution(of: code)
        switch result {
        case .verified, .adHoc: cache.store(auditToken, result)
        case .unresolved, .invalidSignature: break
        }
        return result
    }

    /// Whether the kernel reports the process behind this audit token as running valid code
    /// (CS_VALID), with no file on disk needed. False once the process is gone, and for a token of
    /// another image: the kernel checks the PID version in it.
    public static func kernelReportsValid(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        var status: UInt32 = 0
        // CS_OPS_STATUS is 0 and CS_VALID is 1 (xnu, bsd/sys/codesign.h).
        guard csops_audittoken(pid_t(bitPattern: token.val.5), 0, &status, MemoryLayout<UInt32>.size, &token) == 0 else {
            return false
        }
        return status & 1 != 0
    }

    /// What the kernel alone says about the code behind this audit token, for a process whose
    /// program file Security cannot read: its cdhash, while the kernel reports the code valid. The
    /// signature on disk is not checked, so this is never a signing identity: no rule matches it,
    /// block-all drops it, and in ask mode an approval names this exact build. The kernel checks
    /// each page the process runs against the code directory this cdhash names.
    static func kernelResolution(auditToken: Data, valid: (Data) -> Bool = kernelReportsValid,
                                 cdhash: (Data) -> String? = kernelCDHash) -> IdentityResolution {
        guard valid(auditToken), let hash = cdhash(auditToken), validCDHash(hash) else { return .unresolved }
        return .adHoc(cdhash: hash)
    }

    /// The cdhash of the code the kernel loaded for the process behind this audit token
    /// (CS_OPS_CDHASH), as `codesign -dvvv` prints it. nil once the process is gone, and for a
    /// token of another image.
    public static func kernelCDHash(auditToken: Data) -> String? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        var hash = [UInt8](repeating: 0, count: 20)
        // CS_OPS_CDHASH is 5 (xnu, bsd/sys/codesign.h).
        let result = hash.withUnsafeMutableBytes {
            csops_audittoken(pid_t(bitPattern: token.val.5), 5, $0.baseAddress, $0.count, &token)
        }
        guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// This boot's session UUID (kern.bootsessionuuid), which a stored identity cache is tied to.
    public static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// The kernel's dynamic status only: no signature or disk validation.
    public static func runningCodeIsValid(_ code: SecCode) -> Bool {
        var information: CFDictionary?
        let dynamic = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(dynamic, SecCSFlags(rawValue: kSecCSDynamicInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let status = info[kSecCodeInfoStatus as String] as? NSNumber else { return false }
        return status.uint32Value & SecCodeStatus.valid.rawValue != 0
    }

    public static func resolution(of code: SecCode) -> IdentityResolution {
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        var information: CFDictionary?
        // Security's documented polymorphic C API accepts SecCode here despite
        // its SecStaticCode Swift signature. Keep the dynamic object: converting
        // with SecCodeCopyStaticCode would discard the runtime status flags.
        let dynamic = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(dynamic, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              let status = info[kSecCodeInfoStatus as String] as? NSNumber,
              status.uint32Value & SecCodeStatus.valid.rawValue != 0 else { return .invalidSignature }
        // One SecCodeCheckValidity per path: each call already checks the
        // dynamic status, that the running code matches its signature and the
        // strict bundle structure. Invalidated signed code fails in that call
        // and never falls into unmatched.
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        if flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            // Valid ad hoc signatures satisfy validity without an identity anchor.
            guard teamID == nil, SecCodeCheckValidity(code, strict, nil) == errSecSuccess else { return .invalidSignature }
            // kSecCodeInfoUnique is the cdhash, 20 bytes. Approvals for ad hoc code name it, so
            // code without one cannot be named at all.
            guard let unique = info[kSecCodeInfoUnique as String] as? Data, unique.count == 20 else { return .unresolved }
            return .adHoc(cdhash: unique.map { String(format: "%02x", $0) }.joined())
        }
        guard let signingID = info[kSecCodeInfoIdentifier as String] as? String, validSigningID(signingID) else {
            return SecCodeCheckValidity(code, strict, nil) == errSecSuccess ? .unresolved : .invalidSignature
        }
        if let teamID, !validTeamID(teamID) { return .invalidSignature }
        // Check the dynamic guest against the exact signed metadata (see requirementText). An ad hoc
        // signature cannot satisfy either anchor.
        guard let exact = requirement(requirementText(signingID: signingID, teamID: teamID)),
              SecCodeCheckValidity(code, strict, exact) == errSecSuccess else { return .invalidSignature }
        return .verified(SigningIdentity(signingID: signingID, teamID: teamID))
    }

    /// Where the code behind this audit token lives on disk, for the event a hook reads. Taken from
    /// the same guest as the identity, or, when Security cannot read the file (see `resolve`), from
    /// the kernel by the same audit token; never from a PID alone. nil when the system does not say.
    public static func path(auditToken: Data?) -> String? {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return kernelPath(auditToken: auditToken)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    /// The executable's path as the kernel has it for this audit token. proc_pidpath_audittoken
    /// checks the PID version in the token, so it never names another process.
    static func kernelPath(auditToken: Data) -> String? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// The identity a rule needs for the app or binary at `path`, for `blackice init`: its signing
    /// identifier, and its Team ID unless it is Apple platform code. The signature on disk must
    /// satisfy the same requirement the filter checks a running process against. nil for code that
    /// is unsigned, ad hoc signed or invalid, which a rule cannot name.
    public static func identity(atPath path: String) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let signingID = info[kSecCodeInfoIdentifier as String] as? String, validSigningID(signingID) else { return nil }
        if let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
           flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 { return nil }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        if let teamID, !validTeamID(teamID) { return nil }
        guard let exact = requirement(requirementText(signingID: signingID, teamID: teamID)),
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), exact) == errSecSuccess
        else { return nil }
        return SigningIdentity(signingID: signingID, teamID: teamID)
    }

    /// The identity of a hook program the daemon just started, which the kernel already checked
    /// against its launch requirement (HookRunner). A PID is good enough here, unlike in the filter:
    /// while the child runs, the PID cannot name another process, and a child that already exited
    /// names no code. The check covers the code running now and the file on disk it came from; a
    /// file replaced after the start no longer matches.
    public static func resolve(childPID pid: pid_t) -> IdentityResolution {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return .unresolved }
        return resolution(of: code)
    }

    public static func currentResolution() -> IdentityResolution {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unresolved }
        return resolution(of: code)
    }

    public static func current() -> SigningIdentity? { currentResolution().verifiedIdentity }
}
