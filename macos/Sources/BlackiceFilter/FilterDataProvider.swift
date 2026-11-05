// The network extension: an NEFilterDataProvider that decides each new flow with
// BlackiceCore.FilterPolicy. This file is NetworkExtension glue only; it compiles but cannot
// run until Blackice.app is signed with the Developer ID (docs/phase-0.md).
//
// Adapted from blackice-poc macos/FilterExtension/FilterDataProvider.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/FilterExtension/FilterDataProvider.swift).
// Kept: filter settings that also capture loopback; configuration snapshots replaced only by a
// higher generation and a bad update never replacing a working one; held flows for reading the
// TLS ClientHello, at most 256 and for 10 s, ended when the configuration changes; unified
// logging, which is diagnostic and can drop records. Changed: decisions come from
// FilterPolicy (modes and [[allow]] rules) instead of blackice-poc's per-app policies, the
// configuration is ProviderConfiguration, and every decided flow gets one log line.
//
// Phase 2 (ask mode), also compiled only: flows wait paused while their host is looked up
// (HostAddressCache) and while an event waits for an answer (AskState). Answers and the pending
// list come in over XPC (BlackiceXPC.FilterServer); events and verdicts go out to the daemon on
// its connection. The maintenance timer drops paused flows at their deadline. A stop drops every
// paused and held flow. A configuration change ends them too, and cancels their events: the new
// configuration decides each one again, lets go what it allows outright and drops the rest
// (FilterPolicy.afterChange). A flow decided with the configuration from before a change neither
// starts to wait nor is let through by an answer after it, and each event carries the generation
// it was raised under. A deny is remembered for 10 minutes (AskState.denials): the app's new
// connections to that host are dropped with no event, until an approval or a configuration change.
//
// Names from DNS answers, also compiled only: in ask and block-all the system resolver's port-53
// flows are filtered in both directions instead of allowed outright. DNSFlowTable reads the
// queries and the responses that answer them, every byte passes unchanged, and DNSNameTable
// keeps address -> names. A new flow carries the names its address was given for
// (FlowFacts.dnsNames), and FilterPolicy decides a flow with no host name on the name when there
// is exactly one. Ask mode drops a paused flow that the server already sees as connected after
// FilterPolicy.connectedHoldSeconds, keeping its event open.
//
// Connections by address, also compiled only: a flow with no name is asked about by its address,
// which is then the event's host (FilterPolicy.eventHost).
//
// Accept-all's dry run of ask mode, also compiled only: each new flow is still allowed at once,
// and its log line adds what ask mode would have decided (FilterPolicy.dryRun), for `blackice
// report`. Nothing is held, read, looked up or asked for it.
//
// A dropped flow fails in the app with "Bad file descriptor" (EBADF) on connect, as ssh showed on
// a Mac: NEFilterNewFlowVerdict.drop() and NEFilterDataVerdict.drop() take no error code, and
// macOS's content filter offers no verdict that refuses with another one.
import Darwin
import Foundation
import Network
import BlackiceCore
import BlackiceXPC
import NetworkExtension
import os

@objc(BlackiceFilterDataProvider)
final class FilterDataProvider: NEFilterDataProvider, FilterServiceHandler {
    static let maximumHeld = 256
    static let serverNameDeadline: TimeInterval = 10
    /// More than any DNS message over UDP, so each datagram comes whole in one callback: XNU's
    /// content filter copies at most the peek size of a datagram to the provider, and lets a
    /// datagram through only once all of it is passed.
    static let dnsPeekBytes = 65_536

    private let snapshots = ProviderSnapshotStore()
    private let lifecycle = DispatchQueue(label: "com.valentorassa.blackice.filter.lifecycle")
    private var runID: UUID?
    private var observation: NSKeyValueObservation?
    private var timer: DispatchSourceTimer?
    private let heldLock = NSLock()
    private var held: [UUID: Held] = [:]
    private let flowLog = Logger(subsystem: BlackiceIdentifiers.logSubsystem, category: "flows")
    private let controlLog = Logger(subsystem: BlackiceIdentifiers.logSubsystem, category: "control")

    // Ask mode. askLock guards `ask` and `lookups`; it is never taken while holding heldLock.
    private let askLock = NSLock()
    private var ask = AskState<Paused>()
    private var lookups = LookupWaiters<Paused>()
    private let addresses = HostAddressCache(resolver: SystemHostResolver())
    private let resolverQueue = DispatchQueue(label: "com.valentorassa.blackice.filter.resolver", attributes: .concurrent)
    private var server: FilterServer?

    // Names from DNS answers. dnsLock guards `dnsFlows` only and is never held with another lock.
    private let dnsLock = NSLock()
    private var dnsFlows = DNSFlowTable<UUID, NEFilterSocketFlow>()
    private let dnsNames = DNSNameTable()

    private struct Held {
        let flow: NEFilterSocketFlow
        let facts: FlowFacts
        let generation: UInt64
        let deadline: TimeInterval
        var reader: TLSServerNameReader
    }

    /// A flow paused by this provider: waiting for a lookup or for an answer.
    private struct Paused {
        enum Stage { case newFlow, data }
        let flow: NEFilterFlow
        let facts: FlowFacts
        /// Set when the flow was paused after its TLS server name was read.
        let serverName: String?
        /// Whether that hello had the encrypted_client_hello extension, for its verdict's reason.
        let echPresent: Bool
        let stage: Stage
        let generation: UInt64
    }

    /// What to tell NetworkExtension now.
    private enum Step { case allow, drop, hold, pause, learnNames }

    /// What to do once askLock is released.
    private enum After {
        case nothing
        case lookUp(String)
        /// With the generation of the configuration the event was raised under.
        case send(HookEvent, generation: UInt64)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let identifier = UUID()
        let candidate: ProviderConfiguration
        do {
            candidate = try ProviderConfiguration(vendorConfiguration: filterConfiguration.vendorConfiguration)
        } catch {
            control("start_refused", "invalid_configuration")
            completionHandler(error)
            return
        }
        lifecycle.sync {
            observation = nil
            timer?.cancel(); timer = nil
            snapshots.clear()
            runID = identifier
            _ = try? snapshots.install(candidate)
        }
        apply(Self.makeSettings()) { [weak self] error in
            guard let lifecycle = self?.lifecycle else { completionHandler(error); return }
            lifecycle.async { [weak self] in
                guard let self, self.runID == identifier else { completionHandler(error); return }
                if let error {
                    self.runID = nil
                    self.snapshots.clear()
                    self.control("start_failed", "filter_settings_failed")
                    completionHandler(error)
                    return
                }
                self.observation = self.observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
                    guard let self else { return }
                    self.lifecycle.async {
                        guard self.runID == identifier else { return }
                        self.reloadConfiguration()
                    }
                }
                self.control("started", self.snapshots.read()?.summary ?? "no_configuration")
                // Also catches a change saved while the settings were being applied.
                self.reloadConfiguration()
                self.startMaintenance()
                self.startServer()
                completionHandler(nil)
            }
        }
    }

    /// Every flow goes to the provider, including loopback, which the default rules leave out.
    /// FilterPolicy then allows loopback in every mode unless blackice.toml says loopback = false;
    /// the settings stay the same either way, since they are applied only at start.
    /// No rule for IPv4-mapped loopback (::ffff:127.0.0.1/104): NetworkExtension reads that address
    /// as IPv4, refuses a prefix over 32 and fails the whole start (macOS 27.0.1).
    static func makeSettings() -> NEFilterSettings {
        let loopback = [("127.0.0.1", 8), ("::1", 128)]
        let rules = loopback.map { address, prefix in
            NEFilterRule(networkRule: NENetworkRule(
                destinationNetwork: NWHostEndpoint(hostname: address, port: "0"),
                prefix: prefix, protocol: .any), action: .filterData)
        }
        return NEFilterSettings(rules: rules, defaultAction: .filterData)
    }

    /// The XPC listener on NEMachServiceName, accepting only the blackice binary of our team.
    /// Without it ask mode still pauses flows, and their deadline drops them. The name is this
    /// build's own (Peers.machServiceName), read from this extension's Info.plist. resume()
    /// reports nothing, so xpc_listening names the service but does not prove launchd gave it.
    private func startServer() {
        server?.stop()
        server = nil
        guard let teamID = CodeIdentity.current()?.teamID,
              let service = Peers.machServiceName(teamID: teamID, extensionInfo: Bundle.main.infoDictionary ?? [:]),
              let server = FilterServer(machServiceName: service, teamID: teamID, handler: self,
                                        report: { [weak self] line in self?.control("xpc", line) }) else {
            control("xpc_unavailable", "no_team_or_mach_service")
            return
        }
        self.server = server
        server.start()
        control("xpc_listening", service)
    }

    private func reloadConfiguration() {
        do {
            let candidate = try ProviderConfiguration(vendorConfiguration: filterConfiguration.vendorConfiguration)
            guard try snapshots.install(candidate) else { return }
            // What waits under the old configuration is decided again by the new one: what it
            // allows outright goes on, the rest is dropped (FilterPolicy.afterChange).
            let decide = { [addresses] (facts: FlowFacts, serverName: String?, echPresent: Bool) in
                FilterPolicy.afterChange(facts, serverName: serverName, echPresent: echPresent, snapshot: candidate,
                                         address: { addresses.check(host: $0, address: $1) })
            }
            endHeld(matching: { _ in true }) { decide($0.facts, nil, false) }
            endPaused { decide($0.facts, $0.serverName, $0.echPresent) }
            control("configuration_installed", candidate.summary)
        } catch {
            // A bad or stale update never replaces the configuration that works.
            control("configuration_rejected", "\(error)")
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            self.runID = nil
            self.observation = nil
            self.timer?.cancel(); self.timer = nil
            self.server?.stop(); self.server = nil
            self.dropHeld(reason: "provider_stopped") { _ in true }
            self.endPaused { _ in .drop(reason: "provider_stopped") }
            self.askLock.lock()
            self.ask.approvals.removeAll()
            self.askLock.unlock()
            self.addresses.removeAll()
            self.dnsLock.lock()
            let reading = self.dnsFlows.removeAll()
            self.dnsLock.unlock()
            for flow in reading { self.update(flow, using: .allow(), for: .any) }
            self.dnsNames.removeAll()
            self.control("stopped", "reason_\(reason.rawValue)")
            self.snapshots.clear()
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let snapshot = snapshots.read()
        let socket = flow as? NEFilterSocketFlow
        let endpoint = socket?.remoteEndpoint as? NWHostEndpoint
        let tcp = socket?.socketType == SOCK_STREAM && socket?.socketProtocol == IPPROTO_TCP
        let udp = socket?.socketType == SOCK_DGRAM && socket?.socketProtocol == IPPROTO_UDP
        let internet = socket?.socketFamily == AF_INET || socket?.socketFamily == AF_INET6
        let direction: FlowDirection = flow.direction == .outbound ? .outbound :
            (flow.direction == .inbound ? .inbound : .unknown)
        let address = endpoint.flatMap { BlackiceCore.IPAddress($0.hostname) }
        let facts = FlowFacts(direction: direction, identity: CodeIdentity.resolve(auditToken: flow.sourceAppAuditToken),
                              internetSocket: internet && (tcp || udp), tcp: tcp,
                              hostname: socket?.remoteHostname, port: endpoint.flatMap { UInt16($0.port) },
                              remoteAddress: address,
                              process: flow.sourceProcessAuditToken.map { CodeIdentity.resolve(auditToken: $0) },
                              dnsNames: dnsNames.names(for: address))
        let paused = Paused(flow: flow, facts: facts, serverName: nil, echPresent: false, stage: .newFlow,
                            generation: snapshot?.generation ?? 0)
        // Accept-all's dry run of ask mode, for the log line only: it changes nothing for the flow.
        let would = snapshot.flatMap { FilterPolicy.dryRun(facts, snapshot: $0) }
        askLock.lock()
        let verdict = FilterPolicy.decide(facts, snapshot: snapshot, context: context(now: Self.now))
        let (step, after) = place(verdict, paused, snapshot, now: Self.now, would: would)
        askLock.unlock()
        perform(after)
        switch step {
        case .allow: return .allow()
        case .drop: return .drop()
        case .pause: return .pause()
        case .hold: return hold(flow, facts, snapshot)
        case .learnNames:
            guard let socket else { return .allow() }
            dnsLock.lock()
            let reading = dnsFlows.add(flow.identifier, flow: socket, stream: tcp, now: Self.now)
            dnsLock.unlock()
            // A full table only means this flow's answers go unread; it passes either way.
            guard reading else { return .allow() }
            return .filterDataVerdict(withFilterInbound: true, peekInboundBytes: Self.dnsPeekBytes,
                                      filterOutbound: true, peekOutboundBytes: Self.dnsPeekBytes)
        }
    }

    /// Holds a flow to read its TLS ClientHello: from handleNewFlow, and when a flow paused at
    /// the new-flow stage is resumed.
    private func hold(_ flow: NEFilterFlow, _ facts: FlowFacts, _ snapshot: ProviderConfiguration?) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow, let snapshot else {
            log(facts, .drop(reason: "hold_failed"), snapshot)
            return .drop()
        }
        heldLock.lock()
        guard held.count < Self.maximumHeld, held[flow.identifier] == nil else {
            heldLock.unlock()
            log(facts, .drop(reason: "hold_capacity"), snapshot)
            return .drop()
        }
        held[flow.identifier] = Held(flow: socket, facts: facts, generation: snapshot.generation,
                                     deadline: Self.now + Self.serverNameDeadline,
                                     reader: TLSServerNameReader())
        heldLock.unlock()
        // The 5-byte record header first; no byte is passed until a verdict.
        return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                  filterOutbound: true, peekOutboundBytes: 5)
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        if let verdict = dnsData(flow, offset: offset, bytes: readBytes, outbound: true) { return verdict }
        let snapshot = snapshots.read()
        heldLock.lock()
        guard var entry = held[flow.identifier] else {
            heldLock.unlock()
            return .drop()
        }
        let result: TLSHelloResult
        if snapshot?.generation != entry.generation { result = .deny("configuration_changed") }
        else if Self.now >= entry.deadline { result = .deny("server_name_timeout") }
        else { result = entry.reader.receive(readBytes, offset: offset) }
        if case .needMore(let total) = result {
            held[flow.identifier] = entry
            heldLock.unlock()
            return NEFilterDataVerdict(passBytes: 0, peekBytes: total)
        }
        held.removeValue(forKey: flow.identifier)
        heldLock.unlock()

        var serverName: String?
        var echPresent = false
        if case .serverName(let name, let ech) = result { (serverName, echPresent) = (name, ech) }
        let paused = Paused(flow: flow, facts: entry.facts, serverName: serverName, echPresent: echPresent, stage: .data,
                            generation: entry.generation)
        askLock.lock()
        let verdict = FilterPolicy.decide(entry.facts, serverName: result, snapshot: snapshot, context: context(now: Self.now))
        let (step, after) = place(verdict, paused, snapshot, now: Self.now)
        askLock.unlock()
        perform(after)
        switch step {
        case .allow, .learnNames: return .allow()
        case .pause: return .pause()
        case .drop, .hold: return .drop()
        }
    }

    /// Only the system resolver's DNS flows ask for inbound data.
    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                    readBytes: Data) -> NEFilterDataVerdict {
        dnsData(flow, offset: offset, bytes: readBytes, outbound: false) ?? .allow()
    }

    /// A DNS flow whose inbound data ended is let go, not forgotten, so a late outbound callback
    /// still passes instead of being dropped as a flow nobody held.
    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        dnsLock.lock()
        dnsFlows.letGo(flow.identifier, now: Self.now)
        dnsLock.unlock()
        return .allow()
    }

    /// A DNS flow of the system resolver: every byte passes, whatever the reader makes of it.
    /// nil for any other flow. In accept-all, or with no configuration, the flow is let go.
    private func dnsData(_ flow: NEFilterFlow, offset: Int, bytes: Data, outbound: Bool) -> NEFilterDataVerdict? {
        let learning = snapshots.read().map { $0.mode != .acceptAll } ?? false
        dnsLock.lock()
        let result: DNSFlowTable<UUID, NEFilterSocketFlow>.DataResult
        if learning {
            result = dnsFlows.data(flow.identifier, bytes, offset: offset, outbound: outbound, now: Self.now)
        } else {
            result = dnsFlows.letGo(flow.identifier, now: Self.now) ? .stop([]) : .unknown
        }
        dnsLock.unlock()
        switch result {
        case .unknown:
            return nil
        case .pass(let learned):
            dnsNames.record(learned)
            return NEFilterDataVerdict(passBytes: bytes.count, peekBytes: Self.dnsPeekBytes)
        case .stop(let learned):
            dnsNames.record(learned)
            return .allow()
        }
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        dnsLock.lock()
        let dns = dnsFlows.letGo(flow.identifier, now: Self.now)
        dnsLock.unlock()
        if dns { return .allow() }
        heldLock.lock()
        let entry = held.removeValue(forKey: flow.identifier)
        heldLock.unlock()
        // An app that opens two connections at once (IPv6 and IPv4) uses the first one up and closes
        // the other before it writes a byte: nothing was cut, and the log says so.
        if let entry {
            let reason = entry.reader.received == 0 ? "closed_before_hello" : "tls_unparsed"
            log(entry.facts, .drop(reason: reason), snapshots.read())
        }
        return .drop()
    }

    // MARK: - Ask mode

    /// Under askLock. `resolved` stands in for the cache right after a lookup, so a flow is
    /// decided on the answers it waited for even if they expire meanwhile.
    private func context(now: TimeInterval,
                         resolved: (host: String, answers: Set<BlackiceCore.IPAddress>)? = nil) -> PolicyContext {
        PolicyContext(
            approved: { [approvals = ask.approvals] identity, host in
                approvals.covers(ApprovalKey(identity: identity, host: host), now: now)
            },
            address: { [addresses] host, address in
                if let resolved, resolved.host == host { return HostAddressCache.check(address, against: resolved.answers) }
                return addresses.check(host: host, address: address)
            },
            denied: { [denials = ask.denials] identity, host in
                denials.covers(ApprovalKey(identity: identity, host: host), now: now)
            })
    }

    /// Under askLock: turns a verdict into what NetworkExtension hears now and what follows.
    /// `would` is accept-all's dry run of ask mode, logged with an allow or a drop.
    private func place(_ verdict: FlowVerdict, _ paused: Paused, _ snapshot: ProviderConfiguration?,
                       now: TimeInterval, would: String? = nil) -> (Step, After) {
        let facts = paused.facts
        // A configuration change installs the new snapshot, then ends what is paused under
        // askLock. A flow decided with the old snapshot that gets here after that drop must not
        // start to wait: its event would outlive the configuration it was raised under.
        switch verdict {
        case .resolveHost, .ask:
            guard FilterPolicy.isCurrent(paused.generation, installed: snapshots.read()) else {
                log(facts, .drop(reason: "configuration_changed"), snapshot, serverName: paused.serverName)
                return (.drop, .nothing)
            }
        default:
            break
        }
        switch verdict {
        case .allow:
            log(facts, verdict, snapshot, serverName: paused.serverName, would: would)
            return (.allow, .nothing)
        case .learnNames:
            log(facts, verdict, snapshot, serverName: paused.serverName)
            return (.learnNames, .nothing)
        case .drop:
            log(facts, verdict, snapshot, serverName: paused.serverName, would: would)
            return (.drop, .nothing)
        case .readServerName:
            guard paused.stage == .newFlow else {
                log(facts, .drop(reason: "server_name_unusable"), snapshot, serverName: paused.serverName)
                return (.drop, .nothing)
            }
            return (.hold, .nothing)
        case .resolveHost(let host):
            switch lookups.add(paused, host: host) {
            case .startLookup: return (.pause, .lookUp(host))
            case .waiting: return (.pause, .nothing)
            case .full:
                log(facts, .drop(reason: "lookup_capacity"), snapshot, serverName: paused.serverName)
                return (.drop, .nothing)
            }
        case .ask(_, let addressMatches):
            // A flow with no name is asked about by its address: the event's host is then its ip.
            guard let snapshot, let identity = facts.identity.appIdentity,
                  let host = FilterPolicy.eventHost(facts, serverName: paused.serverName),
                  let port = facts.port, let address = facts.remoteAddress else {
                log(facts, .drop(reason: "ask_incomplete"), snapshot, serverName: paused.serverName)
                return (.drop, .nothing)
            }
            let key = PendingKey(identity: identity, host: host, port: port)
            let added = ask.pending.add(paused, key: key, addressMatches: addressMatches, now: now,
                                        timeout: TimeInterval(snapshot.config.timeoutSeconds),
                                        holdFor: FilterPolicy.holdLimit(facts, afterServerName: paused.stage == .data)) { seconds in
                try HookEvent.connection(app: HookEvent.App(identity, path: CodeIdentity.path(auditToken: paused.flow.sourceAppAuditToken)),
                                         host: host, ip: address.description, port: port,
                                         deadline: Date().addingTimeInterval(seconds))
            }
            switch added {
            case .raised(let event):
                log(facts, verdict, snapshot, serverName: paused.serverName)
                return (.pause, .send(event, generation: paused.generation))
            case .joined:
                log(facts, verdict, snapshot, serverName: paused.serverName)
                return (.pause, .nothing)
            case .full:
                log(facts, .drop(reason: "ask_capacity"), snapshot, serverName: paused.serverName)
                return (.drop, .nothing)
            }
        }
    }

    private func perform(_ after: After) {
        switch after {
        case .nothing:
            break
        case .lookUp(let host):
            resolverQueue.async { [weak self] in self?.finishLookup(host) }
        case .send(let event, let generation):
            // With the generation it was raised under, so the daemon runs that configuration's
            // hooks or none. A configuration installed since has dropped the event's flows.
            guard FilterPolicy.isCurrent(generation, installed: snapshots.read()) else {
                control("event_not_sent", "configuration_changed")
                return
            }
            if server?.send(.event(event, generation: generation)) != true { control("event_not_sent", "no_daemon") }
        }
    }

    /// On resolverQueue: resolves, then decides again every flow that waited for this host.
    private func finishLookup(_ host: String) {
        let answers = addresses.lookUp(host)
        let snapshot = snapshots.read()
        let now = Self.now
        var outcomes: [(Paused, Step, After)] = []
        askLock.lock()
        for paused in lookups.finish(host) {
            let verdict: FlowVerdict
            if paused.generation != snapshot?.generation {
                verdict = .drop(reason: "configuration_changed")
            } else {
                let context = context(now: now, resolved: (host, answers))
                verdict = paused.serverName.map {
                    FilterPolicy.decide(paused.facts, serverName: .serverName($0, echPresent: paused.echPresent),
                                        snapshot: snapshot, context: context)
                } ?? FilterPolicy.decide(paused.facts, snapshot: snapshot, context: context)
            }
            let (step, after) = place(verdict, paused, snapshot, now: now)
            outcomes.append((paused, step, after))
        }
        askLock.unlock()
        for (paused, step, after) in outcomes {
            switch step {
            // .hold comes only at the new-flow stage on the TLS port, where resume holds the flow.
            case .allow, .learnNames, .hold: resume(paused, allow: true)
            case .drop: resume(paused, allow: false)
            case .pause: break // waiting for an answer, or for another lookup of the same host
            }
            perform(after)
        }
    }

    /// Resumes a flow paused by this provider. Called outside flow callbacks. A flow paused at
    /// the new-flow stage that still needs its server name read (TCP on the TLS port, named by
    /// the system or by a DNS answer) resumes into the hold: NEFilterDataProvider.h takes a
    /// new-flow verdict, such as filterDataVerdict, for a flow paused in handleNewFlow. With
    /// `outright`, the allow is a configuration's own verdict for the flow (FilterPolicy
    /// afterChange), which reads no server name, so the flow passes at once.
    private func resume(_ paused: Paused, allow: Bool, outright: Bool = false) {
        let verdict: NEFilterVerdict
        switch paused.stage {
        case .newFlow:
            if allow && !outright && FilterPolicy.needsServerName(paused.facts) {
                verdict = hold(paused.flow, paused.facts, snapshots.read())
            } else {
                verdict = allow ? NEFilterNewFlowVerdict.allow() : NEFilterNewFlowVerdict.drop()
            }
        case .data: verdict = allow ? NEFilterDataVerdict.allow() : NEFilterDataVerdict.drop()
        }
        resumeFlow(paused.flow, with: verdict)
    }

    /// An answer taken just before a configuration change lets nothing through after it.
    private func release(_ releases: [Release<Paused>]) {
        let snapshot = snapshots.read()
        for release in FilterPolicy.current(releases, installed: snapshot, generation: \.generation) {
            resume(release.flow, allow: release.allow)
            log(release.flow.facts, release.allow ? .allow(reason: release.reason) : .drop(reason: release.reason),
                snapshot, serverName: release.flow.serverName)
        }
    }

    /// Ends every paused flow, waiting for a lookup or for an answer, without an answer: each one
    /// gets `verdict`, and an allow lets it through at once. Their events are cancelled, and the
    /// remembered denials forgotten (AskState.endAll).
    private func endPaused(_ verdict: (Paused) -> FlowVerdict) {
        askLock.lock()
        let entries = ask.endAll()
        let waiting = lookups.removeAll()
        askLock.unlock()
        let snapshot = snapshots.read()
        for paused in waiting + entries.flatMap({ $0.flows.map(\.flow) }) {
            let decided = verdict(paused)
            if case .allow = decided { resume(paused, allow: true, outright: true) } else { resume(paused, allow: false) }
            log(paused.facts, decided, snapshot, serverName: paused.serverName)
        }
        for entry in entries { server?.send(.verdict(.cancelled, eventID: entry.event.id)) }
    }

    // MARK: - FilterServiceHandler (called on XPC queues)

    /// What the daemon runs hooks with: the configuration saved with Touch ID, as installed now.
    func currentConfiguration() -> ProviderConfiguration? {
        snapshots.read()
    }

    func pendingReply() -> PendingReply {
        let now = Self.now
        askLock.lock(); defer { askLock.unlock() }
        return PendingReply(events: ask.pending.summaries(now: now), approvals: ask.approvals.summaries(now: now),
                            denials: ask.denials.summaries(now: now))
    }

    func answer(_ request: AnswerRequest) -> AnswerReply {
        askLock.lock()
        let outcome = ask.answer(request, now: Self.now)
        askLock.unlock()
        release(outcome.released)
        for (eventID, verdict) in outcome.verdicts { server?.send(.verdict(verdict, eventID: eventID)) }
        control("answer", "\(request.kind.rawValue) \(request.authorization.rawValue) \(outcome.reply.reason)")
        return outcome.reply
    }

    // MARK: - Maintenance

    private func startMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.now
            self.dropHeld(reason: "server_name_timeout") { $0.deadline <= now }
            self.askLock.lock()
            let (released, timedOut) = self.ask.expire(now: now)
            self.askLock.unlock()
            self.release(released)
            for eventID in timedOut { self.server?.send(.verdict(.timedOut, eventID: eventID)) }
            // Idle DNS flows stop being read; their data passes from now on.
            self.dnsLock.lock()
            let idle = self.dnsFlows.expire(now: now)
            self.dnsLock.unlock()
            for flow in idle { self.update(flow, using: .allow(), for: .any) }
        }
        self.timer = timer
        timer.resume()
    }

    /// Called outside flow callbacks, where NetworkExtension allows update().
    private func dropHeld(reason: String, matching predicate: (Held) -> Bool) {
        endHeld(matching: predicate) { _ in .drop(reason: reason) }
    }

    /// Ends the held flows that match: each one gets `verdict`, and an allow lets its data
    /// through without the server name. Called outside flow callbacks.
    private func endHeld(matching predicate: (Held) -> Bool, verdict: (Held) -> FlowVerdict) {
        heldLock.lock()
        let removed = held.filter { predicate($0.value) }
        for id in removed.keys { held.removeValue(forKey: id) }
        heldLock.unlock()
        let snapshot = snapshots.read()
        for entry in removed.values {
            let decided = verdict(entry)
            if case .allow = decided {
                update(entry.flow, using: .allow(), for: .any)
            } else {
                update(entry.flow, using: .drop(), for: .outbound)
            }
            log(entry.facts, decided, snapshot)
        }
    }

    /// Verdict, reason and app are public so `log show` and `blackice report` can count them; the
    /// host and the rest are private (FlowLogLine.publicText).
    private func log(_ facts: FlowFacts, _ verdict: FlowVerdict, _ snapshot: ProviderConfiguration?,
                     serverName: String? = nil, would: String? = nil) {
        let line = FlowLogLine(flow: facts, verdict: verdict, snapshot: snapshot, serverName: serverName, would: would)
        flowLog.notice("flow \(line.publicText, privacy: .public) \(line.json(), privacy: .private)")
    }

    private func control(_ event: String, _ detail: String) {
        controlLog.notice("control \(event, privacy: .public) \(detail, privacy: .public)")
    }
}
