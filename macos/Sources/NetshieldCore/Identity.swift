// Ported from blackice macos/Shared/AppConfiguration.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice/blob/45a7870/macos/Shared/AppConfiguration.swift).
// Only the identity types and their validators came over. Changes: public, Sendable; ad hoc
// code carries its cdhash; AppIdentity and the cdhash validators are new (phase 2).

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
    /// Valid code signed ad hoc, with no certificate, named by its code directory hash.
    case adHoc(cdhash: String)
    case unresolved
    case invalidSignature

    public var verifiedIdentity: SigningIdentity? {
        if case .verified(let identity) = self { return identity }
        return nil
    }

    /// What an approval can name: the signing identity, or the cdhash of ad hoc code.
    public var appIdentity: AppIdentity? {
        switch self {
        case .verified(let identity): return .signed(identity)
        case .adHoc(let cdhash): return .cdhash(cdhash)
        case .unresolved, .invalidSignature: return nil
        }
    }

    public var label: String {
        switch self {
        case .verified(let identity): return identity.label
        case .adHoc(let cdhash): return AppIdentity.cdhash(cdhash).label
        case .unresolved: return "unknown"
        case .invalidSignature: return "invalid_signature"
        }
    }
}

/// The code an approval, a pending event or `netshield approve` names. Signed code is named by
/// its signing identity, which survives updates. Ad hoc signed code has none, so it is named by
/// its cdhash: a rebuild changes the cdhash, and the next connection asks again.
public enum AppIdentity: Hashable, Sendable {
    case signed(SigningIdentity)
    /// 40 lower-case hex digits; see `validCDHash`.
    case cdhash(String)

    public var label: String {
        switch self {
        case .signed(let identity): return identity.label
        case .cdhash(let hash): return "cdhash/" + hash
        }
    }

    /// Every field in the form that messages and log lines may carry.
    public var isValid: Bool {
        switch self {
        case .signed(let identity): return validSigningID(identity.signingID) && (identity.teamID.map(validTeamID) ?? true)
        case .cdhash(let hash): return validCDHash(hash)
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

/// A cdhash as `codesign -dvvv` prints it: 20 bytes, 40 lower-case hex digits.
public func validCDHash(_ text: String) -> Bool {
    text.utf8.count == 40 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

/// Also accepts upper-case hex. Returns the lower-case form, or nil.
public func normalizeCDHash(_ text: String) -> String? {
    guard text.utf8.count == 40, text.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
    let lower = text.lowercased()
    return validCDHash(lower) ? lower : nil
}
