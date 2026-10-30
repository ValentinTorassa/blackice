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
    static func resolve(auditToken: Data?) -> SigningIdentity? {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }
        return identity(of: code)
    }

    static func identity(of code: SecCode) -> SigningIdentity? {
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard let anchor = requirement("anchor apple generic"),
              SecCodeCheckValidity(code, strict, anchor) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let signingID = info[kSecCodeInfoIdentifier as String] as? String, validSigningID(signingID) else { return nil }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let expression: String
        if let teamID {
            guard validTeamID(teamID) else { return nil }
            expression = "anchor apple generic and identifier \"\(signingID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        } else {
            // Only Apple platform code can be considered known without a Team ID.
            expression = "anchor apple and identifier \"\(signingID)\""
        }
        // Recheck the dynamic guest against the exact signed metadata, including
        // the certificate's OU. An ad hoc signature cannot satisfy either anchor.
        guard let exact = requirement(expression), SecCodeCheckValidity(code, strict, exact) == errSecSuccess else { return nil }
        return SigningIdentity(signingID: signingID, teamID: teamID)
    }

    static func current() -> SigningIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return identity(of: code)
    }
}
