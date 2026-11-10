// The network extension: an NEFilterDataProvider that decides each new flow with
// BlackiceCore.FilterPolicy. This file is NetworkExtension glue only; it compiles but cannot
// run until Blackice.app is signed with the Developer ID (docs/phase-0.md).
//
// Adapted from blackice-poc macos/FilterExtension/FilterDataProvider.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/FilterExtension/FilterDataProvider.swift).
// Kept: filter settings that also capture loopback; configuration snapshots replaced only by a
// higher generation and a bad update never replacing a working one; held flows for reading the
// TLS ClientHello, at most 256, ended when the configuration changes; unified logging, which is
// diagnostic and can drop records. Changed: decisions come from FilterPolicy (modes and [[allow]]
// rules) instead of blackice-poc's per-app policies, the configuration is ProviderConfiguration,
// and every decided flow gets one log line. A held flow may stay quiet for 120 s before its first
// byte and has 10 s from it for the hello (BlackiceCore.HelloDeadline); blackice-poc gave it 10 s
// from the connect. One app holds at most 64 flows, and a new flow may take the place of a quiet
// one (BlackiceCore.HoldPool).
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
    /// More than any DNS message over UDP, so each datagram comes whole in one callback: XNU's
    /// content filter copies at most the peek size of a datagram to the provider, and lets a
    /// datagram through only once all of it is passed.
    static let dnsPeekBytes = 65_536

    private let snapshots = ProviderSnapshotStore()
    private let lifecycle = DispatchQueue(label: "com.valentorassa.blackice.filter.lifecycle")
    private var runID: UUID?
    private var observation: NSKeyValueObservation?
    private var timer: DispatchSourceTimer?
    /// Seconds of maintenance since start, and the identity cache's change count when last saved.
    private var maintenanceTicks = 0
    private var savedIdentityChanges = -1
    private var savedApprovalsRevision = -1
    /// After a save that failed, the next try waits until then.
    private var approvalsSaveNotBefore: TimeInterval = 0
    private let heldLock = NSLock()
    private var held: [UUID: Held] = [:]
    private let flowLog = Logger(subsystem: BlackiceIdentifiers.logSubsystem, category: "flows")
    private let controlLog = Logger(subsystem: BlackiceIdentifiers.logSubsystem, category: "control")

    // Ask mode. askLock guards `ask` and `lookups`; it is never taken while holding heldLock, and
    // may be taken inside snapshots.withInstalled, never the other way round.
    private let askLock = NSLock()
    private var ask = AskState<Paused>()
    private var lookups = LookupWaiters<Paused>()
    /// Under askLock. Connections of an app in a loop of drops, waiting for theirs.
    private var repeated = RepeatedDrops<Paused>()
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
        var deadline: HelloDeadline
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

    /// Counts sleep (see continuousSeconds), so an approval ends on time across sleep.
    private static var now: TimeInterval { continuousSeconds() }

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
            restoreIdentities()
            restoreApprovals()
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
            // Waits for a release in progress, whose flows endPaused would not find (release).
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
            // The approvals stay in memory: an answer still on its way after this changes them
            // and saves them again, so a deny is never lost to the stop.
            self.saveApprovals(force: true)
            self.addresses.removeAll()
            self.dnsLock.lock()
            let reading = self.dnsFlows.removeAll()
            self.dnsLock.unlock()
            for flow in reading { self.update(flow, using: .allow(), for: .any) }
            self.dnsNames.removeAll()
            self.saveIdentities()
            self.control("stopped", "reason_\(reason.rawValue)")
            self.snapshots.clear()
            completionHandler()
        }
    }

    /// A link-local remote address with its interface, from the flow's endpoint as Network gives
    /// it (macOS 15 on). Read only when the host endpoint's text gives no address, or a link-local
    /// one with no interface, which could be any host on any link: on 10 November 2026
    /// identityservicesd's connections to a link-local peer were all dropped as `no_host`, with
    /// nothing to ask about.
    private static func linkLocal(_ socket: NEFilterSocketFlow?) -> BlackiceCore.IPAddress? {
        guard #available(macOS 15.0, *), case .hostPort(.ipv6(let remote), _)? = socket?.remoteFlowEndpoint,
              let interface = remote.interface,
              let address = BlackiceCore.IPAddress(bytes: Array(remote.rawValue), scope: UInt32(interface.index)),
              address.isLinkLocal, address.scope != 0 else { return nil }
        return address
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
        var address = endpoint.flatMap { BlackiceCore.IPAddress($0.hostname) }
        if address?.isCheckable != true, let scoped = Self.linkLocal(socket),
           address == nil || address?.bytes == scoped.bytes {
            address = scoped
        }
        let identity = CodeIdentity.resolve(auditToken: flow.sourceAppAuditToken)
        // A cdhash rule reads the path of ad hoc code, to tell an interpreter by its name
        // (Interpreters); answers and approvals read any interpreter's script (ScriptScope).
        let kernelPath = flow.sourceAppAuditToken.flatMap { CodeIdentity.kernelPath(auditToken: $0) }
        var executablePath: String?
        if case .adHoc = identity { executablePath = kernelPath }
        var title: String?
        let scriptScope = ScriptScope.of(executablePath: kernelPath) {
            let named = flow.sourceAppAuditToken.map(ProcessArguments.named(auditToken:))
            title = named?.title
            return named?.script
        }
        let facts = FlowFacts(direction: direction, identity: identity,
                              internetSocket: internet && (tcp || udp), tcp: tcp,
                              hostname: socket?.remoteHostname, port: endpoint.flatMap { UInt16($0.port) },
                              remoteAddress: address,
                              process: flow.sourceProcessAuditToken.map { CodeIdentity.resolve(auditToken: $0) },
                              dnsNames: dnsNames.names(for: address), dnsAliases: dnsNames.aliases(for: address),
                              executablePath: executablePath,
                              scriptScope: scriptScope, title: title)
        let paused = Paused(flow: flow, facts: facts, serverName: nil, echPresent: false, stage: .newFlow,
                            generation: snapshot?.generation ?? 0)
        // Accept-all's dry run of ask mode, for the log line only: it changes nothing for the flow.
        let would = snapshot.flatMap { FilterPolicy.dryRun(facts, snapshot: $0) }
        askLock.lock()
        let verdict = FilterPolicy.decide(facts, snapshot: snapshot, context: context(now: Self.now, scope: facts.scriptScope))
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
    /// the new-flow stage is resumed. It may take the place of a quiet one (HoldPool.admit).
    private func hold(_ flow: NEFilterFlow, _ facts: FlowFacts, _ snapshot: ProviderConfiguration?) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow, let snapshot else {
            log(facts, .drop(reason: "hold_failed"), snapshot)
            return .drop()
        }
        heldLock.lock()
        let admission: HoldPool.Admission<UUID> = held[flow.identifier] != nil ? .refuse("hold_capacity") :
            HoldPool.admit(facts.identity.appIdentity, held: held.lazy.map {
                HeldPlace(id: $0.key, app: $0.value.facts.identity.appIdentity, deadline: $0.value.deadline)
            })
        guard case .hold(let evicting) = admission else {
            heldLock.unlock()
            if case .refuse(let reason) = admission { log(facts, .drop(reason: reason), snapshot) }
            return .drop()
        }
        let evicted = evicting.flatMap { held.removeValue(forKey: $0) }
        held[flow.identifier] = Held(flow: socket, facts: facts, generation: snapshot.generation,
                                     deadline: HelloDeadline(heldAt: Self.now),
                                     reader: TLSServerNameReader())
        heldLock.unlock()
        if let evicted {
            // Out of `held`, a byte it sends drops it anyway; update() is not allowed inside the
            // flow callback this may run in, so the drop is told from the lifecycle queue.
            log(evicted.facts, .drop(reason: "evicted_quiet"), snapshot)
            lifecycle.async { [weak self] in self?.update(evicted.flow, using: .drop(), for: .outbound) }
        }
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
        let now = Self.now
        if !readBytes.isEmpty { entry.deadline.bytesArrived(now: now) }
        let result: TLSHelloResult
        if snapshot?.generation != entry.generation { result = .deny("configuration_changed") }
        else if entry.deadline.passed(now: now) { result = .deny(entry.deadline.reason) }
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
        let verdict = FilterPolicy.decide(entry.facts, serverName: result, snapshot: snapshot,
                                          context: context(now: Self.now, scope: entry.facts.scriptScope))
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
        case .pass(let learned, let aliases):
            dnsNames.record(learned, aliases: aliases)
            return NEFilterDataVerdict(passBytes: bytes.count, peekBytes: Self.dnsPeekBytes)
        case .stop(let learned, let aliases):
            dnsNames.record(learned, aliases: aliases)
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
    /// For a flow of `scope`: an interpreter's approvals and denials count only for their script.
    private func context(now: TimeInterval, scope: ScriptScope,
                         resolved: (host: String, answers: Set<BlackiceCore.IPAddress>)? = nil) -> PolicyContext {
        PolicyContext(
            approved: { [approvals = ask.approvals] identity, host in
                approvals.covers(identity, host: host, scope: scope, now: now)
            },
            address: { [addresses] host, address in
                if let resolved, resolved.host == host { return HostAddressCache.check(address, against: resolved.answers) }
                // Answers a few seconds old that miss the address are looked up again first.
                return addresses.checkOrRefresh(host: host, address: address)
            },
            denied: { [denials = ask.denials] identity, host in
                denials.covers(identity, host: host, scope: scope, now: now)
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
            return drop(paused, verdict, snapshot, now: now, would: would)
        case .readServerName:
            guard paused.stage == .newFlow else {
                return drop(paused, .drop(reason: "server_name_unusable"), snapshot, now: now)
            }
            return (.hold, .nothing)
        case .resolveHost(let host):
            switch lookups.add(paused, host: host, app: facts.identity.appIdentity) {
            case .startLookup: return (.pause, .lookUp(host))
            case .waiting: return (.pause, .nothing)
            case .full:
                return drop(paused, .drop(reason: "lookup_capacity"), snapshot, now: now)
            case .appFull:
                return drop(paused, .drop(reason: "lookup_capacity_app"), snapshot, now: now)
            }
        case .ask(_, let addressMatches):
            // A flow with no name is asked about by its address: the event's host is then its ip.
            guard let snapshot, let identity = facts.identity.appIdentity,
                  let host = FilterPolicy.eventHost(facts, serverName: paused.serverName),
                  let port = facts.port, let address = facts.remoteAddress else {
                return drop(paused, .drop(reason: "ask_incomplete"), snapshot, now: now)
            }
            let key = PendingKey(identity: identity, host: host, port: port, scope: facts.scriptScope)
            let added = ask.pending.add(paused, key: key, addressMatches: addressMatches, now: now,
                                        timeout: TimeInterval(snapshot.config.timeoutSeconds),
                                        holdFor: FilterPolicy.holdLimit(facts, afterServerName: paused.stage == .data)) { seconds in
                // The script read when the flow began, the one the event's key and its answer cover,
                // and the title of the process that opened this flow, the first of the event's.
                try HookEvent.connection(app: HookEvent.App(identity, path: CodeIdentity.path(auditToken: paused.flow.sourceAppAuditToken),
                                                            script: facts.scriptScope.script, title: facts.title),
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
                return drop(paused, .drop(reason: "ask_capacity"), snapshot, now: now)
            case .appFull:
                return drop(paused, .drop(reason: "ask_capacity_app"), snapshot, now: now)
            }
        }
    }

    /// Under askLock: a drop that `place` decided, at whatever stage of the flow. An app that opens
    /// the next connection as soon as one is dropped has its TCP ones wait for their drop
    /// (RepeatedDrops): such a flow is logged now and stays paused, or is paused here, until the
    /// maintenance timer drops it.
    private func drop(_ paused: Paused, _ verdict: FlowVerdict, _ snapshot: ProviderConfiguration?,
                      now: TimeInterval, would: String? = nil) -> (Step, After) {
        let facts = paused.facts
        // A flow decided under a configuration that another has replaced, or that a stop has
        // cleared, is dropped now and not counted: the change has already ended what was delayed,
        // and this drop is the change's, not the app's. A flow that came with no configuration
        // installed, and still has none, is dropped like every flow then, and those count.
        if (snapshots.read()?.generation ?? 0) != paused.generation {
            log(facts, verdict, snapshot, serverName: paused.serverName, would: would)
            return (.drop, .nothing)
        }
        switch repeated.add(paused, app: facts.identity.label, waits: facts.tcp, now: now) {
        case .dropNow:
            log(facts, verdict, snapshot, serverName: paused.serverName, would: would)
            return (.drop, .nothing)
        case .delayed:
            log(facts, verdict, snapshot, serverName: paused.serverName, would: would)
            return (.pause, .nothing)
        case .dropUnlogged:
            return (.drop, .nothing)
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

    /// On resolverQueue: resolves, then decides again every flow that waited for this host. From
    /// the generation check to the last resume no configuration is installed (`release`).
    private func finishLookup(_ host: String) {
        let answers = addresses.lookUp(host)
        let now = Self.now
        var afters: [After] = []
        snapshots.withInstalled { snapshot in
            var outcomes: [(Paused, Step, After)] = []
            askLock.lock()
            for paused in lookups.finish(host) {
                let verdict: FlowVerdict
                if paused.generation != snapshot?.generation {
                    verdict = .drop(reason: "configuration_changed")
                } else {
                    let context = context(now: now, scope: paused.facts.scriptScope, resolved: (host, answers))
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
                afters.append(after)
            }
        }
        for after in afters { perform(after) }
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

    /// An answer taken just before a configuration change lets nothing through after it. The
    /// answer took these flows off the pending list, so the change's endPaused cannot find them:
    /// the generation check and every resume run with the installed configuration held, and a
    /// change waits for them or comes first and turns each allow into a drop.
    private func release(_ releases: [Release<Paused>]) {
        snapshots.withInstalled { snapshot in
            for release in FilterPolicy.current(releases, installed: snapshot, generation: \.generation) {
                resume(release.flow, allow: release.allow)
                log(release.flow.facts, release.allow ? .allow(reason: release.reason) : .drop(reason: release.reason),
                    snapshot, serverName: release.flow.serverName)
            }
        }
    }

    /// Ends every paused flow, waiting for a lookup or for an answer, without an answer: each one
    /// gets `verdict`, and an allow lets it through at once. Their events are cancelled, and the
    /// remembered denials forgotten (AskState.endAll).
    private func endPaused(_ verdict: (Paused) -> FlowVerdict) {
        askLock.lock()
        let entries = ask.endAll()
        let waiting = lookups.removeAll()
        let delayed = repeated.removeAll()
        askLock.unlock()
        let snapshot = snapshots.read()
        // Dropped by the configuration they came under, and logged then.
        for paused in delayed { resume(paused, allow: false) }
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
        // Right away, so a revoked approval does not come back after a crash.
        lifecycle.async { [weak self] in self?.saveApprovals() }
        release(outcome.released)
        for (eventID, verdict) in outcome.verdicts { server?.send(.verdict(verdict, eventID: eventID)) }
        control("answer", "\(request.kind.rawValue) \(request.authorization.rawValue) \(outcome.reply.reason)")
        return outcome.reply
    }

    func forgetApprovals() -> AnswerReply {
        askLock.lock()
        let count = ask.forgetApprovals(now: Self.now)
        askLock.unlock()
        // Right away, so the file does not bring them back after a crash.
        lifecycle.async { [weak self] in self?.saveApprovals() }
        control("answer", "forget touch_id forgotten \(count)")
        return .forgotten(count)
    }

    // MARK: - Maintenance

    private func startMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.now
            self.endHeld(matching: { $0.deadline.passed(now: now) }) { .drop(reason: $0.deadline.reason) }
            self.askLock.lock()
            let (released, timedOut) = self.ask.expire(now: now)
            let overdue = self.repeated.due(now: now)
            let unlogged = self.repeated.takeUnlogged()
            self.askLock.unlock()
            self.release(released)
            // Logged when they were delayed.
            for paused in overdue { self.resume(paused, allow: false) }
            if unlogged > 0 { self.control("drops_not_logged", "\(unlogged)") }
            for eventID in timedOut { self.server?.send(.verdict(.timedOut, eventID: eventID)) }
            // Idle DNS flows stop being read; their data passes from now on.
            self.dnsLock.lock()
            let idle = self.dnsFlows.expire(now: now)
            self.dnsLock.unlock()
            for flow in idle { self.update(flow, using: .allow(), for: .any) }
            self.maintenanceTicks += 1
            if self.maintenanceTicks % 60 == 0 { self.saveIdentities() }
            // Each minute even with no change, so the file's time of day stays close to now.
            self.saveApprovals(refresh: self.maintenanceTicks % 60 == 0)
        }
        self.timer = timer
        timer.resume()
    }

    // MARK: - Identities across runs

    /// Where the identity cache waits for the extension's next run in this boot: after an upgrade
    /// or a stop and start, a running app whose program file was removed meanwhile (an app updated
    /// while it runs) keeps the identity checked while the file was there (CodeIdentity.resolve).
    private static let identitiesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.valentorassa.blackice.filter", isDirectory: true)
        .appendingPathComponent("identities.json")

    /// On the lifecycle queue.
    private func restoreIdentities() {
        guard let url = Self.identitiesURL, let boot = CodeIdentity.bootSession(),
              let data = try? Data(contentsOf: url) else { return }
        control("identities_restored", "\(CodeIdentity.cache.restore(data, boot: boot))")
        savedIdentityChanges = CodeIdentity.cache.changes
    }

    /// On the lifecycle queue. Only processes that still run are kept.
    private func saveIdentities() {
        let changes = CodeIdentity.cache.changes
        guard changes != savedIdentityChanges, let url = Self.identitiesURL, let boot = CodeIdentity.bootSession(),
              let data = CodeIdentity.cache.encoded(boot: boot, keep: CodeIdentity.kernelReportsValid) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            _ = chmod(url.path, 0o600)
            savedIdentityChanges = changes
        } catch {
            control("identities_not_saved", "\(error)")
        }
    }

    // MARK: - Approvals across runs

    /// Where the approvals wait for the extension's next run, after an upgrade or a restart of the
    /// Mac (SavedApprovals). Root's, like the identity cache.
    private static let approvalsURL = identitiesURL?.deletingLastPathComponent().appendingPathComponent("approvals.json")

    /// On the lifecycle queue, at start.
    private func restoreApprovals() {
        guard let url = Self.approvalsURL, let data = try? Data(contentsOf: url) else { return }
        let timeOfDay = Date().timeIntervalSince1970
        askLock.lock()
        // A start after a stop in the same process: what is in memory is what the file holds, or
        // newer, and the file could bring back an approval a deny has just removed.
        guard ask.approvals.count == 0 else {
            askLock.unlock()
            control("approvals_kept", "in_memory")
            return
        }
        let added = ask.approvals.restore(data, now: Self.now, timeOfDay: timeOfDay)
        savedApprovalsRevision = ask.approvals.revision
        askLock.unlock()
        control("approvals_restored", added.map { "\($0)" } ?? "invalid_file")
    }

    /// On the lifecycle queue. Writes the approvals when they changed since the last save; with
    /// `refresh`, also when they did not and there are some. A save that fails is tried again a
    /// minute later, or at once with `force`.
    private func saveApprovals(refresh: Bool = false, force: Bool = false) {
        guard let url = Self.approvalsURL else { return }
        let now = Self.now
        guard force || now >= approvalsSaveNotBefore else { return }
        askLock.lock()
        let revision = ask.approvals.revision
        let changed = revision != savedApprovalsRevision
        let data = changed || ((refresh || force) && ask.approvals.count > 0)
            ? ask.approvals.saved(now: now, timeOfDay: Date().timeIntervalSince1970) : nil
        askLock.unlock()
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            _ = chmod(url.path, 0o600)
            savedApprovalsRevision = revision
            approvalsSaveNotBefore = 0
        } catch {
            approvalsSaveNotBefore = now + 60
            control("approvals_not_saved", "\(error)")
        }
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
