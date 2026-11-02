// The CLI's and the daemon's side of the XPC protocol. Compiled, not run (see Protocols.swift).
import Foundation
import NetshieldCore

public struct FilterClientError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One request and its reply, for `netshield pending`, `approve` and `deny`.
public final class FilterClient {
    public static let replyTimeout: TimeInterval = 10

    private let connection: NSXPCConnection

    /// Connects to the extension of `teamID`, the team this binary is signed with.
    public init(teamID: String) throws {
        guard let service = Peers.machServiceName(teamID: teamID),
              let requirement = Peers.filterRequirement(teamID: teamID) else {
            throw FilterClientError("this binary has no valid Team ID")
        }
        connection = NSXPCConnection(machServiceName: service, options: [])
        // Checked on every reply: only our own extension can answer.
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FilterServiceXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    public func pending() throws -> PendingReply {
        try call(PendingReply.self) { proxy, done in
            proxy.pending(try Messages.encode(PendingRequest()), reply: done)
        }
    }

    public func answer(_ request: AnswerRequest) throws -> AnswerReply {
        try call(AnswerReply.self) { proxy, done in
            proxy.answer(try Messages.encode(request), reply: done)
        }
    }

    private func call<Reply: CheckedMessage>(_ type: Reply.Type,
                                             _ send: (FilterServiceXPC, @escaping (Data) -> Void) throws -> Void) throws -> Reply {
        let box = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            box.fail("cannot reach the network extension (\((error as NSError).domain) \((error as NSError).code)); " +
                     "is netshield started?")
        }) as? FilterServiceXPC else { throw FilterClientError("cannot make the XPC proxy") }
        try send(proxy) { data in box.finish(data) }
        guard let data = box.wait(timeout: Self.replyTimeout) else {
            throw FilterClientError(box.failure ?? "the network extension did not answer in time")
        }
        do {
            return try Messages.decode(Reply.self, from: data)
        } catch {
            throw FilterClientError("the network extension sent an invalid reply: \(error)")
        }
    }
}

/// A reply or a failure, set once from the XPC queue.
private final class ReplyBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data: Data?
    private(set) var failure: String?
    private var done = false

    func finish(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        data = value
        semaphore.signal()
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        failure = message
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Data? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// The daemon's intake: registers with the extension and turns its messages into events.
/// When the connection ends (the extension stopped or restarted), the stream finishes and the
/// daemon exits with an error, so launchd starts it again and it registers anew.
public final class XPCEventIntake: NSObject, EventIntake, EventReceiverXPC, @unchecked Sendable {
    private let teamID: String
    private let onVerdict: @Sendable (String, Verdict) -> Void
    private let report: @Sendable (String) -> Void
    private let lock = NSLock()
    private var continuation: AsyncStream<HookEvent>.Continuation?
    private var connection: NSXPCConnection?

    public init(teamID: String, onVerdict: @escaping @Sendable (String, Verdict) -> Void,
                report: @escaping @Sendable (String) -> Void) {
        self.teamID = teamID
        self.onVerdict = onVerdict
        self.report = report
    }

    public func events() -> AsyncStream<HookEvent> {
        AsyncStream { continuation in
            guard let service = Peers.machServiceName(teamID: teamID),
                  let requirement = Peers.filterRequirement(teamID: teamID) else {
                report("no valid Team ID")
                continuation.finish()
                return
            }
            let connection = NSXPCConnection(machServiceName: service, options: [])
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: FilterServiceXPC.self)
            connection.exportedInterface = NSXPCInterface(with: EventReceiverXPC.self)
            connection.exportedObject = self
            connection.invalidationHandler = { [report] in
                report("the connection to the network extension ended")
                continuation.finish()
            }
            connection.interruptionHandler = { [report] in
                report("the network extension went away")
                continuation.finish()
            }
            lock.lock()
            self.continuation = continuation
            self.connection = connection
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.close() }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { [report] error in
                report("cannot reach the network extension (\((error as NSError).code))")
                continuation.finish()
            } as? FilterServiceXPC
            guard let proxy, let request = try? Messages.encode(RegisterRequest()) else {
                continuation.finish()
                return
            }
            proxy.register(request) { [report] data in
                guard let reply = try? Messages.decode(RegisterReply.self, from: data), reply.accepted else {
                    report("the network extension refused the registration")
                    continuation.finish()
                    return
                }
                report("registered with the network extension")
            }
        }
    }

    private func close() {
        lock.lock()
        let current = connection
        connection = nil
        continuation = nil
        lock.unlock()
        current?.invalidate()
    }

    public func receive(_ message: Data, reply: @escaping (Bool) -> Void) {
        let decoded: DaemonMessage
        do {
            decoded = try Messages.decode(DaemonMessage.self, from: message)
        } catch {
            report("refused a message from the network extension: \(error)")
            reply(false)
            return
        }
        switch decoded.kind {
        case .event:
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            if let event = decoded.event { continuation?.yield(event) }
        case .verdict:
            if let id = decoded.eventID, let verdict = decoded.verdict { onVerdict(id, verdict) }
        }
        reply(true)
    }
}
