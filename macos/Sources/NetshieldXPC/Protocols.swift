// The XPC protocol between the extension, the daemon and the CLI (phase 2). Compiled, not run:
// nothing here can work until Netshield.app is signed with the Developer ID (docs/phase-0.md).
//
// One connection type, opened by the CLI or the daemon to the extension's Mach service:
//
//   CLI     --pending(PendingRequest)-->    extension  --> PendingReply
//   CLI     --answer(AnswerRequest)-->      extension  --> AnswerReply
//   daemon  --register(RegisterRequest)-->  extension  --> RegisterReply
//   daemon  <--receive(DaemonMessage)--     extension      (events and verdicts, same connection)
//
// The extension cannot reach a LaunchAgent's Mach service, so the daemon opens the connection and
// exports EventReceiverXPC on it; the extension sends events back through that connection.
// Every argument is the JSON of a NetshieldCore message (Messages.swift), decoded and checked on
// receipt. Both ends set the other's code signing requirement (NetshieldCore.Peers) on the
// connection, which NSXPCConnection checks on every message.
import Foundation

/// Exported by the extension on its Mach service.
@objc public protocol FilterServiceXPC {
    /// RegisterRequest -> RegisterReply. The daemon calls it once per connection; from then on
    /// events go to this connection. A later registration replaces it.
    func register(_ request: Data, reply: @escaping (Data) -> Void)
    /// PendingRequest -> PendingReply.
    func pending(_ request: Data, reply: @escaping (Data) -> Void)
    /// AnswerRequest -> AnswerReply.
    func answer(_ request: Data, reply: @escaping (Data) -> Void)
}

/// Exported by the daemon on its connection to the extension.
@objc public protocol EventReceiverXPC {
    /// A DaemonMessage. The reply says whether the daemon accepted it.
    func receive(_ message: Data, reply: @escaping (Bool) -> Void)
}
