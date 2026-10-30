import Darwin
import Foundation
import Network
import NetworkExtension
import os

/// Provider is instantiated by NetworkExtension using the Info.plist class map.
final class FilterDataProvider: NEFilterDataProvider {
    private let snapshots = SnapshotStore()
    private let lifecycle = DispatchQueue(label: "com.blackice.app.filter.lifecycle")
    private var runID: UUID?
    private var observation: NSKeyValueObservation?
    private let logger = Logger(subsystem: AppFilterConstants.logSubsystem, category: "receipts")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let identifier = UUID()
        do {
            let candidate = try readConfiguration()
            try lifecycle.sync {
                observation = nil
                snapshots.clear()
                runID = identifier
                try snapshots.install(candidate)
            }
            apply(Self.makeSettings()) { [weak self] error in
                guard let self else { completionHandler(ConfigurationError.invalid("provider_stopped")); return }
                self.lifecycle.async { [self] in
                    guard self.runID == identifier else {
                        completionHandler(ConfigurationError.invalid("provider_stopped")); return
                    }
                    if let error {
                        self.runID = nil
                        self.snapshots.clear()
                        self.controlEvent("warning", reason: "filter_settings_failed")
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
                    // Also catches a preference change while applySettings was pending.
                    self.reloadConfiguration()
                    self.controlEvent("scope_start", reason: "filter_settings_applied")
                    completionHandler(nil)
                }
            }
        } catch {
            snapshots.clear()
            controlEvent("warning", reason: "invalid_start_configuration")
            completionHandler(ConfigurationError.invalid("invalid_start_configuration"))
        }
    }

    static func makeSettings() -> NEFilterSettings {
        // Default rules exclude loopback. Explicit capture is essential for
        // local-proxy policy; no network settings are applied by this factory.
        let loopback = [("127.0.0.1", 8), ("::1", 128), ("::ffff:127.0.0.1", 104)]
        let rules = loopback.map { address, prefix in
            NEFilterRule(networkRule: NENetworkRule(
                destinationNetwork: NWHostEndpoint(hostname: address, port: "0"),
                prefix: prefix, protocol: .any), action: .filterData)
        }
        return NEFilterSettings(rules: rules, defaultAction: .filterData)
    }

    private func readConfiguration() throws -> AppConfiguration {
        guard let values = filterConfiguration.vendorConfiguration,
              Set(values.keys) == [AppFilterConstants.configurationKey],
              let data = values[AppFilterConstants.configurationKey] as? Data else {
            throw ConfigurationError.invalid("missing_app_configuration")
        }
        return try AppConfiguration(data: data)
    }

    private func reloadConfiguration() {
        do {
            try snapshots.install(readConfiguration())
            controlEvent("policy_activated", reason: "snapshot_installed")
        } catch {
            // Invalid or stale updates cannot replace a working snapshot.
            controlEvent("warning", reason: "configuration_update_rejected")
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            self.runID = nil
            self.observation = nil
            self.controlEvent("scope_end", reason: "filter_stopped")
            self.snapshots.clear()
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let configuration = snapshots.read()
        let socket = flow as? NEFilterSocketFlow
        let endpoint = socket?.remoteEndpoint as? NWHostEndpoint
        // A numeric endpoint is required: remoteHostname does not supply an IP.
        let ip = endpoint.flatMap { IPAddress($0.hostname) }
        let port = endpoint.flatMap { UInt16($0.port) }
        let tcp = socket?.socketType == SOCK_STREAM && socket?.socketProtocol == IPPROTO_TCP
        let udp = socket?.socketType == SOCK_DGRAM && socket?.socketProtocol == IPPROTO_UDP
        let internet = socket?.socketFamily == AF_INET || socket?.socketFamily == AF_INET6
        let direction: FlowFacts.Direction = flow.direction == .outbound ? .outbound :
            (flow.direction == .inbound ? .inbound : .unknown)
        let app = CodeIdentity.resolve(auditToken: flow.sourceAppAuditToken)
        let process = flow.sourceProcessAuditToken == flow.sourceAppAuditToken ? app :
            CodeIdentity.resolve(auditToken: flow.sourceProcessAuditToken)
        let facts = FlowFacts(direction: direction, app: app, process: process,
                              supportedSocket: internet && (tcp || udp),
                              hostname: socket?.remoteHostname, ip: ip, port: port)
        let result = AppEvaluator.evaluate(facts, configuration: configuration)
        emit(Receipt.flow(facts, result: result, hostnameMode: configuration?.hostnameMode))
        return result.decision.allowed ? .allow() : .drop()
    }

    private func controlEvent(_ event: String, reason: String) {
        let config = snapshots.read()
        var receipt = Receipt(scope: "app-provider", policy: config?.id ?? "unavailable",
                              generation: config?.generation ?? 0, point: "control", event: event)
        receipt.reason = reason
        receipt.detail = "backend=network_extension;scope_kind=app;durable_receipts=unavailable"
        emit(receipt)
    }

    private func emit(_ receipt: Receipt) {
        do {
            let line = try receipt.jsonLine()
            // Diagnostic transport only: no concurrent writes to Zig scope files.
            // Unified logging can drop/truncate records. It is NOT a durable ledger.
            logger.notice("\(line, privacy: .public)")
        } catch {
            logger.error("receipt_encoding_failed;durable_receipts=unavailable")
        }
    }
}
