import Foundation

/// Collects the first bytes of a held flow until the ClientHello's server name can be read.
/// Same rules as blackice-poc's TLSInspection (see TLSClientHello.swift), without an expected host:
/// blackice matches the name against the rules afterwards. Bounded, refuses replaced prefixes
/// and bad offsets, and fails closed on anything it cannot parse.
public struct TLSServerNameReader: Sendable {
    private var bytes = Data()

    public init() {}

    /// How many bytes came in so far: none when the app closed the connection before writing.
    public var received: Int { bytes.count }

    public mutating func receive(_ data: Data, offset: Int) -> TLSHelloResult {
        guard offset >= 0, offset <= bytes.count, data.count <= TLSClientHello.maximumBytes - offset else {
            return .deny("tls_unparsed")
        }
        let overlap = min(data.count, bytes.count - offset)
        guard bytes.subdata(in: offset..<(offset + overlap)) == data.prefix(overlap) else {
            return .deny("tls_unparsed")
        }
        bytes.append(data.dropFirst(overlap))
        return TLSClientHello.inspect(bytes)
    }
}
