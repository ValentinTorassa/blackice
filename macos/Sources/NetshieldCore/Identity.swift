// Ported from blackice macos/Shared/AppConfiguration.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice/blob/45a7870/macos/Shared/AppConfiguration.swift).
// Only the identity types and their validators came over. Changes: public, Sendable.

/// A signing identity checked against the running code by `CodeIdentity`.
/// `teamID` is nil only for Apple platform code.
public struct SigningIdentity: Equatable, Hashable, Sendable {
    public let signingID: String
    public let teamID: String?

    public init(signingID: String, teamID: String?) {
        self.signingID = signingID
        self.teamID = teamID
    }

    public var label: String { (teamID ?? "apple") + "/" + signingID }
}

public enum IdentityResolution: Equatable, Sendable {
    case verified(SigningIdentity)
    case adHoc
    case unresolved
    case invalidSignature

    public var verifiedIdentity: SigningIdentity? {
        if case .verified(let identity) = self { return identity }
        return nil
    }

    public var label: String {
        switch self {
        case .verified(let identity): return identity.label
        case .adHoc: return "adhoc"
        case .unresolved: return "unknown"
        case .invalidSignature: return "invalid_signature"
        }
    }
}

/// ASCII letters, digits, '-', '.' and '_', 1 to 255 bytes. These values go into a
/// code signing requirement string, so nothing that could close a quote gets through.
public func validSigningID(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= 255 && text.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
    }
}

/// Ten upper-case ASCII letters or digits.
public func validTeamID(_ text: String) -> Bool {
    text.utf8.count == 10 && text.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
}
