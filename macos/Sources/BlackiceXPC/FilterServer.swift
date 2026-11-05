// The extension's side of the XPC protocol. Compiled, not run (see Protocols.swift).
import Foundation
import BlackiceCore

/// What the extension does with checked requests. Called on the XPC connection's queue.
public protocol FilterServiceHandler: AnyObject {
    func pendingReply() -> PendingReply
    func answer(_ request: AnswerRequest) -> AnswerReply
    /// The configuration the extension decides with now, which `blackice start` and `mode` saved.
    /// The daemon gets it with each registration and runs its hooks; nil refuses the registration.
    func currentConfiguration() -> ProviderConfiguration?
}

/// Listens on the extension's Mach service, accepts only the blackice binary of the same team,
/// and keeps the daemon's connection to send it events.
public final class FilterServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let clientRequirement: String
    private weak var handler: FilterServiceHandler?
    private let lock = NSLock()
    private var daemon: NSXPCConnection?
    private let report: (String) -> Void

    /// nil when the Team ID is not valid. `report` gets one line per refused connection or message.
    public init?(machServiceName: String, teamID: String, handler: FilterServiceHandler,
                 report: @escaping (String) -> Void) {
        guard let requirement = Peers.clientRequirement(teamID: teamID) else { return nil }
        listener = NSXPCListener(machServiceName: machServiceName)
        clientRequirement = requirement
        self.handler = handler
        self.report = report
        super.init()
        listener.delegate = self
    }

    public func start() { listener.resume() }

    public func stop() {
        listener.invalidate()
        lock.lock()
        let current = daemon
        daemon = nil
        lock.unlock()
        current?.invalidate()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Checked by NSXPCConnection on every message from this peer; a message from code that
        // does not satisfy it never reaches the exported object.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: FilterServiceXPC.self)
        connection.exportedObject = ClientEndpoint(server: self, connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: EventReceiverXPC.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.lock()
            if let connection, self.daemon === connection { self.daemon = nil }
            self.lock.unlock()
        }
        connection.resume()
        return true
    }

    /// True when a daemon is registered to receive events.
    public var hasDaemon: Bool {
        lock.lock(); defer { lock.unlock() }
        return daemon != nil
    }

    /// True when `connection` is the registered daemon's.
    fileprivate func isDaemon(_ connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return daemon === connection
    }

    /// Sends one message to the registered daemon. False when there is no daemon or the message
    /// could not be encoded; delivery itself is not confirmed.
    @discardableResult
    public func send(_ message: DaemonMessage) -> Bool {
        lock.lock()
        let current = daemon
        lock.unlock()
        guard let current, let data = try? Messages.encode(message),
              let proxy = current.remoteObjectProxyWithErrorHandler({ [weak self] error in
                  self?.report("daemon_send_failed \((error as NSError).code)")
              }) as? EventReceiverXPC else { return false }
        proxy.receive(data) { [weak self] accepted in
            if !accepted { self?.report("daemon_refused_message") }
        }
        return true
    }

    /// Makes `connection` the daemon's and returns the configuration to run hooks with. A daemon
    /// that registers again on its own connection only gets the configuration once more; another
    /// connection replaces it. Whichever copy of the daemon registers, it runs the hooks of the
    /// configuration saved with Touch ID, not hooks of its own.
    fileprivate func register(_ connection: NSXPCConnection) -> RegisterReply {
        guard let configuration = handler?.currentConfiguration() else {
            report("daemon_refused no_configuration")
            return .refused
        }
        lock.lock()
        let previous = daemon
        daemon = connection
        lock.unlock()
        if previous === connection {
            report("daemon_configuration_sent \(configuration.generation)")
        } else {
            previous?.invalidate()
            report("daemon_registered \(configuration.generation)")
        }
        return RegisterReply(generation: configuration.generation, configText: configuration.configText)
    }

    /// The handler's lists and the configuration it decides with, which `start` and `mode` check
    /// against the one they saved.
    fileprivate func pendingReply() -> PendingReply {
        guard let handler else { return PendingReply(events: [], approvals: []) }
        return handler.pendingReply().deciding(with: handler.currentConfiguration())
    }

    fileprivate func answer(_ request: AnswerRequest) -> AnswerReply {
        handler?.answer(request) ?? AnswerReply(status: .refused, reason: "unavailable", message: "the filter is stopping")
    }

    fileprivate func refused(_ what: String, _ error: Error) {
        report("refused_\(what) \(error)")
    }
}

/// The object exported on one client connection.
private final class ClientEndpoint: NSObject, FilterServiceXPC {
    private weak var server: FilterServer?
    private weak var connection: NSXPCConnection?

    init(server: FilterServer, connection: NSXPCConnection) {
        self.server = server
        self.connection = connection
    }

    func register(_ request: Data, reply: @escaping (Data) -> Void) {
        do {
            _ = try Messages.decode(RegisterRequest.self, from: request)
            guard let server, let connection else { throw MessageError("connection", "is gone") }
            reply(Self.encoded(server.register(connection)))
        } catch {
            server?.refused("register", error)
            reply(Self.encoded(RegisterReply.refused))
        }
    }

    func pending(_ request: Data, reply: @escaping (Data) -> Void) {
        do {
            _ = try Messages.decode(PendingRequest.self, from: request)
            reply(Self.encoded(server?.pendingReply() ?? PendingReply(events: [], approvals: [])))
        } catch {
            server?.refused("pending", error)
            reply(Data())
        }
    }

    func answer(_ request: Data, reply: @escaping (Data) -> Void) {
        let answer: AnswerReply
        do {
            let checked = try Messages.decode(AnswerRequest.self, from: request)
            // Only the daemon sends a token, for a hook's answer. The CLI has no way to send one, and
            // a token is taken only on the registered daemon's connection.
            if checked.authorization == .token, !(connection.map { server?.isDaemon($0) == true } ?? false) {
                answer = AnswerReply(status: .refused, reason: "not_the_daemon",
                                     message: "only the registered daemon answers with a token")
            } else {
                answer = server?.answer(checked)
                    ?? AnswerReply(status: .refused, reason: "unavailable", message: "the filter is stopping")
            }
        } catch {
            server?.refused("answer", error)
            answer = AnswerReply(status: .refused, reason: "invalid_request", message: "the request was refused: \(error)")
        }
        reply(Self.encoded(answer))
    }

    private static func encoded(_ message: some CheckedMessage) -> Data {
        (try? Messages.encode(message)) ?? Data()
    }
}
