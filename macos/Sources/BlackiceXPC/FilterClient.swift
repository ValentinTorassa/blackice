// The CLI's and the daemon's side of the XPC protocol. Compiled, not run (see Protocols.swift).
import Foundation
import BlackiceCore

public struct FilterClientError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One request and its reply, for `blackice pending`, `approve` and `deny`.
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
                     "is blackice started?")
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

/// The daemon's intake: registers with the extension, takes the configuration it sends back and
/// turns its messages into events. Each event names the generation of the configuration the
/// extension held when it sent it; when the daemon holds another, it calls `configuration()`,
/// which registers again on the same connection and returns what the extension holds now. The
/// daemon never reads a configuration from anywhere else.
/// When the connection ends (the extension stopped or restarted), the stream finishes and the
/// daemon exits with an error, so launchd starts it again and it registers anew.
public final class XPCEventIntake: NSObject, EventIntake, EventReceiverXPC, @unchecked Sendable {
    private let teamID: String
    private let onVerdict: @Sendable (String, Verdict) -> Void
    private let report: @Sendable (String) -> Void
    private let lock = NSLock()
    private var continuation: AsyncStream<IntakeMessage>.Continuation?
    private var connection: NSXPCConnection?

    public init(teamID: String, onVerdict: @escaping @Sendable (String, Verdict) -> Void,
                report: @escaping @Sendable (String) -> Void) {
        self.teamID = teamID
        self.onVerdict = onVerdict
        self.report = report
    }

    public func messages() -> AsyncStream<IntakeMessage> {
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
            Task { [report] in
                do {
                    let configuration = try await self.configuration()
                    report("registered with the network extension; configuration \(configuration.summary)")
                    continuation.yield(.registered(configuration))
                } catch {
                    report("registration failed: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    /// Registers on the open connection and returns the configuration in the extension's reply.
    /// Registering again on the same connection only asks for the configuration once more.
    public func configuration() async throws -> DaemonConfiguration {
        guard let connection = currentConnection() else { throw FilterClientError("not connected to the network extension") }
        let request = try Messages.encode(RegisterRequest())
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                let error = error as NSError
                once.resume(throwing: FilterClientError("cannot reach the network extension (\(error.domain) \(error.code))"))
            }) as? FilterServiceXPC else {
                once.resume(throwing: FilterClientError("cannot make the XPC proxy"))
                return
            }
            proxy.register(request) { data in
                do {
                    once.resume(returning: try RegisterReply.configuration(from: data))
                } catch {
                    once.resume(throwing: FilterClientError("the network extension did not accept the registration: \(error)"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + FilterClient.replyTimeout) {
                once.resume(throwing: FilterClientError("the network extension did not answer the registration in time"))
            }
        }
    }

    private func currentConnection() -> NSXPCConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
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
            if let event = decoded.event, let generation = decoded.generation {
                continuation?.yield(.event(event, generation: generation))
            }
        case .verdict:
            if let id = decoded.eventID, let verdict = decoded.verdict { onVerdict(id, verdict) }
        }
        reply(true)
    }
}

/// Resumes a continuation once, from whichever of the reply, the error handler and the timeout
/// comes first.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func resume(returning value: Value) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
