import Darwin
import Foundation
import Security

enum CodeIdentity {
    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The audit token includes the process generation. No PID-only lookups,
    /// paths, claimed bundle IDs, parent scans or positive identity cache.
    static func resolve(auditToken: Data?) -> IdentityResolution {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return .unresolved }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return .unresolved }
        return resolution(of: code)
    }

    static func resolution(of code: SecCode) -> IdentityResolution {
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        // Valid ad hoc signatures satisfy validity without an identity anchor.
        // Invalidated signed code must fail here, never fall into unmatched.
        guard SecCodeCheckValidity(code, strict, nil) == errSecSuccess else { return .invalidSignature }
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
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        if flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return teamID == nil ? .adHoc : .invalidSignature
        }
        guard let signingID = info[kSecCodeInfoIdentifier as String] as? String, validSigningID(signingID) else {
            return .unresolved
        }
        let expression: String
        if let teamID {
            guard validTeamID(teamID) else { return .invalidSignature }
            expression = "anchor apple generic and identifier \"\(signingID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        } else {
            // Only Apple platform code can be considered known without a Team ID.
            expression = "anchor apple and identifier \"\(signingID)\""
        }
        // Recheck the dynamic guest against the exact signed metadata, including
        // the certificate's OU. An ad hoc signature cannot satisfy either anchor.
        guard let exact = requirement(expression), SecCodeCheckValidity(code, strict, exact) == errSecSuccess else { return .invalidSignature }
        return .verified(SigningIdentity(signingID: signingID, teamID: teamID))
    }

    static func currentResolution() -> IdentityResolution {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unresolved }
        return resolution(of: code)
    }

    static func current() -> SigningIdentity? { currentResolution().verifiedIdentity }
}
