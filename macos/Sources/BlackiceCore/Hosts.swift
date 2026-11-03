// Ported from blackice-poc macos/Shared/Policy.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/Shared/Policy.swift).
// Only the host name helpers came over. Changes: public API; DomainPattern's initializer
// is failable instead of throwing blackice-poc's ConfigurationError, and it drops the extra
// IP address check, because normalizeHost already refuses numeric names and ':'.

/// True when the last label is all digits or 0x-prefixed hex, the shapes that
/// resolvers may read as an IPv4 address ("2130706433", "127.1", "0x7f000001").
public func looksNumeric(_ text: String) -> Bool {
    let last = text.split(separator: ".", omittingEmptySubsequences: false).last ?? ""
    guard !last.isEmpty else { return false }
    if last.lowercased().hasPrefix("0x") {
        return last.dropFirst(2).utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    return last.utf8.allSatisfy { (48...57).contains($0) }
}

/// ASCII host names only: letters, digits, '-' and '_', labels of 1 to 63 bytes,
/// 253 bytes in all, one optional trailing dot. Returns the lower-cased name, or nil.
public func normalizeHost(_ raw: String) -> String? {
    let text = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    guard !text.isEmpty, text.utf8.count <= 253 else { return nil }
    var labelLength = 0
    for c in text.utf8 {
        switch c {
        case 65...90, 97...122, 48...57, 45, 95: labelLength += 1
        case 46:
            guard labelLength > 0 else { return nil }
            labelLength = 0
        default: return nil
        }
        if labelLength > 63 { return nil }
    }
    return labelLength > 0 && !looksNumeric(text) ? text.lowercased() : nil
}

/// An exact host ("api.example.com") or every subdomain of one ("*.example.com").
/// "*.example.com" does not match "example.com" itself.
public struct DomainPattern: Equatable, Sendable {
    public let source: String
    public let suffix: String
    public let wildcard: Bool

    public init?(_ source: String) {
        let wildcard = source.hasPrefix("*.")
        let base = wildcard ? String(source.dropFirst(2)) : source
        guard let host = normalizeHost(base) else { return nil }
        self.source = source
        self.wildcard = wildcard
        self.suffix = wildcard ? "." + host : host
    }

    /// `host` must already be normalized.
    public func matches(_ host: String) -> Bool {
        wildcard ? host.count > suffix.count && host.hasSuffix(suffix) : host == suffix
    }
}
