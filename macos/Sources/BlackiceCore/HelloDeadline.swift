import Foundation

/// How long a flow held for its TLS ClientHello may take, and what its drop is called when it
/// runs out. An app can open a connection and write nothing for a while: the spare of two opened at
/// once, or one kept ready for the next request. On 5 November 2026 fx and Claude Code (both Bun)
/// lost 175 connections in two days to a deadline of 10 s from the connect. So a flow may stay quiet
/// for `quietSeconds` before its first byte, and has `helloSeconds` from that byte for the whole
/// hello. No byte passes before a verdict either way, so the longer wait lets nothing through.
public struct HelloDeadline: Equatable, Sendable {
    /// Before the first byte.
    public static let quietSeconds: TimeInterval = 120
    /// From the first byte to a whole hello.
    public static let helloSeconds: TimeInterval = 10

    /// When the flow is dropped if it has not been decided.
    public private(set) var at: TimeInterval
    /// Whether a byte has come in.
    public private(set) var started = false

    public init(heldAt now: TimeInterval) {
        at = now + Self.quietSeconds
    }

    /// Called with each outbound callback, before `passed(now:)`: the first one starts the hello's
    /// own time, so a first byte late in the quiet time still gets all of `helloSeconds`.
    public mutating func bytesArrived(now: TimeInterval) {
        guard !started, now < at else { return }
        started = true
        at = now + Self.helloSeconds
    }

    public func passed(now: TimeInterval) -> Bool { now >= at }

    /// The reason a flow dropped at this deadline is logged with.
    public var reason: String { started ? "server_name_timeout" : "idle_before_hello" }
}
