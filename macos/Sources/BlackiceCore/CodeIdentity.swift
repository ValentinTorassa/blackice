// Ported from blackice-poc macos/Shared/CodeIdentity.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/Shared/CodeIdentity.swift).
// Changes: public API, IdentityCache marked @unchecked Sendable (all state is behind its lock);
// ad hoc code comes back with its cdhash, and path(auditToken:) is new (phase 2).
import Darwin
import Foundation
import Security

/// Positive identities of running process images, keyed by the full audit
/// token. The token carries the PID version, which changes on exec, so one key
/// never names two images. Bounded; when full it starts over.
public final class IdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data: IdentityResolution] = [:]
    private let limit: Int

    public init(limit: Int = 4096) { self.limit = limit }

    public func read(_ token: Data) -> IdentityResolution? {
        lock.lock(); defer { lock.unlock() }
        return entries[token]
    }

    public func store(_ token: Data, _ resolution: IdentityResolution) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[token] = resolution
    }

    public func remove(_ token: Data) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

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
    public static func resolve(auditToken: Data?) -> IdentityResolution {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return .unresolved }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return .unresolved }
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
    /// the same guest as the identity, never from a PID. nil when the system does not say.
    public static func path(auditToken: Data?) -> String? {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
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

    /// The identity of a hook program the daemon started suspended and has not reaped. A PID is
    /// safe here, unlike in the filter: until waitpid the PID cannot name another process, and a
    /// suspended child cannot exec anything else. The check covers the code the kernel loaded and
    /// the file on disk it came from; a file replaced after the start no longer matches.
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
