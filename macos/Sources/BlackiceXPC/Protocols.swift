// The XPC protocol between the extension, the daemon and the CLI (phase 2). Compiled, not run:
// nothing here can work until Blackice.app is signed with the Developer ID (docs/phase-0.md).
//
// One connection type, opened by the CLI or the daemon to the extension's Mach service:
//
//   CLI     --pending(PendingRequest)-->    extension  --> PendingReply
//   CLI     --answer(AnswerRequest)-->      extension  --> AnswerReply (after Touch ID)
//   daemon  --register(RegisterRequest)-->  extension  --> RegisterReply (with the configuration)
//   daemon  --answer(AnswerRequest)-->      extension  --> AnswerReply (a hook's, with the token)
//   daemon  <--receive(DaemonMessage)--     extension      (events and verdicts, same connection)
//
// The extension cannot reach a LaunchAgent's Mach service, so the daemon opens the connection and
// exports EventReceiverXPC on it; the extension sends events back through that connection.
// The daemon's hooks and timeout come from the register reply: the configuration saved with
// Touch ID, as the extension holds it. Each event carries that configuration's generation, and a
// daemon holding another generation registers again on the same connection to get the new one.
// Every argument is the JSON of a BlackiceCore message (Messages.swift), decoded and checked on
// receipt. Both ends set the other's code signing requirement (BlackiceCore.Peers) on the
// connection, which NSXPCConnection checks on every message.
import Foundation

/// Exported by the extension on its Mach service.
@objc public protocol FilterServiceXPC {
    /// RegisterRequest -> RegisterReply. From the first call on, events go to this connection, and
    /// a registration from another connection replaces it. Each reply carries the configuration
    /// the extension holds; the daemon calls it again on the same connection when an event names a
    /// generation it does not hold.
    func register(_ request: Data, reply: @escaping (Data) -> Void)
    /// PendingRequest -> PendingReply, which also names the configuration the extension decides with.
    func pending(_ request: Data, reply: @escaping (Data) -> Void)
    /// AnswerRequest -> AnswerReply. One with a token is taken only from the registered daemon's
    /// connection: only the daemon sends them, for its hooks.
    func answer(_ request: Data, reply: @escaping (Data) -> Void)
    /// ForgetRequest -> AnswerReply: `blackice deny --all`, which forgets every approval.
    func forget(_ request: Data, reply: @escaping (Data) -> Void)
}

/// Exported by the daemon on its connection to the extension.
@objc public protocol EventReceiverXPC {
    /// A DaemonMessage. The reply says whether the daemon accepted it.
    func receive(_ message: Data, reply: @escaping (Bool) -> Void)
}
