// Pieces of netshield start, stop and mode that need no system framework, so they can be
// unit-tested: what the Touch ID prompt says, which configurations the CLI refuses to touch,
// and when activation may replace an installed extension.
//
// ExtensionReplacement is ported from blackice macos/Shared/HostAuthorization.swift at commit
// 45a7870 (https://github.com/ValentinTorassa/blackice/blob/45a7870/macos/Shared/HostAuthorization.swift).
// Changes: public, the extension bundle ID is a parameter. The prompt text is new.

public enum ControlAction: Equatable, Sendable {
    case start(ProviderConfiguration)
    case stop
    case mode(from: Mode, to: Mode, generation: UInt64)

    /// One sentence for the terminal and the Touch ID dialog. Every change to filtering asks.
    public var reason: String {
        switch self {
        case .start(let configuration):
            return "netshield: start filtering (\(configuration.summary))"
        case .stop:
            return "netshield: stop filtering and deactivate the network extension"
        case .mode(let from, let to, let generation):
            return "netshield: change the mode from \(from.rawValue) to \(to.rawValue) (generation \(generation))"
        }
    }
}

/// Activation replaces an installed extension only with this extension at the same or a higher
/// CFBundleVersion, so an older signed build cannot replace a newer one. A deliberate rollback is
/// stop, then start.
public enum ExtensionReplacement {
    public static func allowed(existingID: String, existingVersion: String, candidateID: String, candidateVersion: String,
                               extensionID: String = NetshieldIdentifiers.filter) -> Bool {
        guard existingID == extensionID, candidateID == extensionID,
              let existing = version(existingVersion), let candidate = version(candidateVersion) else { return false }
        return !candidate.lexicographicallyPrecedes(existing)
    }

    /// CFBundleVersion: one to three period-separated integers. Trailing zero components are
    /// dropped so "1" and "1.0" compare equal. Anything else is unparseable and refuses.
    public static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= 9, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.last == 0 { numbers.removeLast() }
        return numbers
    }
}

/// The filter preference as loaded, reduced to what the CLI checks before changing it.
public struct SavedFilter: Equatable, Sendable {
    /// Bundle ID of the provider the saved configuration points at; nil when there is none.
    public let providerBundleID: String?
    public let enabled: Bool
    public let configuration: ProviderConfiguration?

    public init(providerBundleID: String?, enabled: Bool, configuration: ProviderConfiguration?) {
        self.providerBundleID = providerBundleID
        self.enabled = enabled
        self.configuration = configuration
    }

    /// Why the CLI must not touch this preference, or nil. A filter that belongs to another
    /// product is never changed or removed.
    public var foreignOwner: String? {
        guard let providerBundleID, providerBundleID != NetshieldIdentifiers.filter else { return nil }
        return providerBundleID
    }
}
