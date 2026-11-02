// The network extension: an NEFilterDataProvider that decides each new flow with
// NetshieldCore.FilterPolicy. This file is NetworkExtension glue only; it compiles but cannot
// run until Netshield.app is signed with the Developer ID (docs/phase-0.md).
//
// Adapted from blackice macos/FilterExtension/FilterDataProvider.swift at commit 45a7870
// (https://github.com/ValentinTorassa/blackice/blob/45a7870/macos/FilterExtension/FilterDataProvider.swift).
// Kept: filter settings that also capture loopback; configuration snapshots replaced only by a
// higher generation and a bad update never replacing a working one; held flows for reading the
// TLS ClientHello, at most 256 and for 10 s, dropped when the configuration changes; unified
// logging, which is diagnostic and can drop records. Changed: decisions come from
// FilterPolicy (modes and [[allow]] rules) instead of blackice's per-app policies, the
// configuration is ProviderConfiguration, and every decided flow gets one log line.
import Darwin
import Foundation
import Network
import NetshieldCore
import NetworkExtension
import os

@objc(NetshieldFilterDataProvider)
final class FilterDataProvider: NEFilterDataProvider {
    static let maximumHeld = 256
    static let serverNameDeadline: TimeInterval = 10

    private let snapshots = ProviderSnapshotStore()
    private let lifecycle = DispatchQueue(label: "com.valentorassa.netshield.filter.lifecycle")
    private var runID: UUID?
    private var observation: NSKeyValueObservation?
    private var timer: DispatchSourceTimer?
    private let heldLock = NSLock()
    private var held: [UUID: Held] = [:]
    private let flowLog = Logger(subsystem: NetshieldIdentifiers.logSubsystem, category: "flows")
    private let controlLog = Logger(subsystem: NetshieldIdentifiers.logSubsystem, category: "control")

    private struct Held {
        let flow: NEFilterSocketFlow
        let facts: FlowFacts
        let generation: UInt64
        let deadline: TimeInterval
        var reader: TLSServerNameReader
    }

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
                completionHandler(nil)
            }
        }
    }

    /// Every flow goes to the provider, including loopback, which the default rules leave out.
    static func makeSettings() -> NEFilterSettings {
        let loopback = [("127.0.0.1", 8), ("::1", 128), ("::ffff:127.0.0.1", 104)]
        let rules = loopback.map { address, prefix in
            NEFilterRule(networkRule: NENetworkRule(
                destinationNetwork: NWHostEndpoint(hostname: address, port: "0"),
                prefix: prefix, protocol: .any), action: .filterData)
        }
        return NEFilterSettings(rules: rules, defaultAction: .filterData)
    }

    private func reloadConfiguration() {
        do {
            let candidate = try ProviderConfiguration(vendorConfiguration: filterConfiguration.vendorConfiguration)
            guard try snapshots.install(candidate) else { return }
            dropHeld(reason: "configuration_changed") { _ in true }
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
            self.dropHeld(reason: "provider_stopped") { _ in true }
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
        let facts = FlowFacts(direction: direction, identity: CodeIdentity.resolve(auditToken: flow.sourceAppAuditToken),
                              internetSocket: internet && (tcp || udp), tcp: tcp,
                              hostname: socket?.remoteHostname, port: endpoint.flatMap { UInt16($0.port) })
        let verdict = FilterPolicy.decide(facts, snapshot: snapshot)
        switch verdict {
        case .allow:
            log(facts, verdict, snapshot)
            return .allow()
        case .drop:
            log(facts, verdict, snapshot)
            return .drop()
        case .readServerName:
            guard let socket, let snapshot else {
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
                                         deadline: ProcessInfo.processInfo.systemUptime + Self.serverNameDeadline,
                                         reader: TLSServerNameReader())
            heldLock.unlock()
            // The 5-byte record header first; no byte is passed until a verdict.
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: 5)
        }
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        let snapshot = snapshots.read()
        heldLock.lock(); defer { heldLock.unlock() }
        guard var entry = held[flow.identifier] else { return .drop() }
        let result: TLSHelloResult
        if snapshot?.generation != entry.generation { result = .deny("configuration_changed") }
        else if ProcessInfo.processInfo.systemUptime >= entry.deadline { result = .deny("server_name_timeout") }
        else { result = entry.reader.receive(readBytes, offset: offset) }
        if case .needMore(let total) = result {
            held[flow.identifier] = entry
            return NEFilterDataVerdict(passBytes: 0, peekBytes: total)
        }
        held.removeValue(forKey: flow.identifier)
        let verdict = FilterPolicy.decide(entry.facts, serverName: result, snapshot: snapshot)
        var serverName: String?
        if case .serverName(let name, _) = result { serverName = name }
        log(entry.facts, verdict, snapshot, serverName: serverName)
        if case .allow = verdict { return .allow() }
        return .drop()
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        heldLock.lock()
        let entry = held.removeValue(forKey: flow.identifier)
        heldLock.unlock()
        if let entry { log(entry.facts, .drop(reason: "tls_unparsed"), snapshots.read()) }
        return .drop()
    }

    private func startMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            let now = ProcessInfo.processInfo.systemUptime
            self?.dropHeld(reason: "server_name_timeout") { $0.deadline <= now }
        }
        self.timer = timer
        timer.resume()
    }

    /// Called outside flow callbacks, where NetworkExtension allows update().
    private func dropHeld(reason: String, matching predicate: (Held) -> Bool) {
        heldLock.lock()
        let removed = held.filter { predicate($0.value) }
        for id in removed.keys { held.removeValue(forKey: id) }
        heldLock.unlock()
        let snapshot = snapshots.read()
        for entry in removed.values {
            update(entry.flow, using: .drop(), for: .outbound)
            log(entry.facts, .drop(reason: reason), snapshot)
        }
    }

    /// Verdict and reason are public so `log show` can count them; the app and host are private.
    private func log(_ facts: FlowFacts, _ verdict: FlowVerdict, _ snapshot: ProviderConfiguration?,
                     serverName: String? = nil) {
        let line = FlowLogLine(flow: facts, verdict: verdict, snapshot: snapshot, serverName: serverName)
        flowLog.notice("flow \(line.verdict, privacy: .public) \(line.reason, privacy: .public) \(line.json(), privacy: .private)")
    }

    private func control(_ event: String, _ detail: String) {
        controlLog.notice("control \(event, privacy: .public) \(detail, privacy: .public)")
    }
}
