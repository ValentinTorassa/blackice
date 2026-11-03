// blackice start, stop, status and mode against macOS: system extension activation,
// NEFilterManager preferences and Touch ID; and since phase 2 pending, approve, deny and daemon
// over XPC to the extension. None of this can run without Blackice.app signed with the
// Developer ID and its provisioning profiles, so it is compiled and reviewed but not yet
// exercised; docs/phase-0.md is the first run.
//
// Adapted from blackice-poc macos/Host/main.swift and macos/Shared/HostAuthorization.swift at
// commit 45a7870 (https://github.com/ValentinTorassa/blackice-poc/blob/45a7870/macos/Host/main.swift).
// Kept: refuse unless this is the signed host, refuse a filter configured by another product,
// fresh Touch ID for every change with no reuse, reload after authenticating and refuse if the
// saved configuration changed meanwhile, never let an older extension replace a newer one.
// Changed: the configuration is blackice's ProviderConfiguration, start/stop each run the whole
// sequence (activate + save, disable + remove + deactivate), output is plain lines.
import Foundation
import LocalAuthentication
import BlackiceCLI
import BlackiceCore
import BlackiceXPC
import NetworkExtension
import SystemExtensions

public final class NESystemControl: SystemControlling {
    /// How long start and stop wait for the system extension request; the first activation
    /// waits for the person to approve it in System Settings.
    static let extensionRequestTimeout: TimeInterval = 600
    static let preferencesTimeout: TimeInterval = 60

    public init() {}

    public func start(configText: String, output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().start(configText: configText, output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        if let owner = saved.foreignOwner { return refuseForeign(owner, output) }
        let candidate: ProviderConfiguration
        do {
            candidate = try ProviderConfiguration.starting(configText: configText, after: saved.configuration)
        } catch {
            output.stderr("blackice start: \(error)")
            return ExitCode.invalidConfig
        }
        guard confirm(.start(candidate), output) else { return ExitCode.noPermission }

        output.stdout("Activating the network extension. The first time, macOS asks you to allow it in System Settings.")
        let activation = runExtensionRequest(
            OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlackiceIdentifiers.filter, queue: .main),
            output)
        guard activation == ExitCode.success else { return activation }

        guard let (manager, current) = loadSaved(output) else { return ExitCode.software }
        if let owner = current.foreignOwner { return refuseForeign(owner, output) }
        guard current.configuration == saved.configuration else { return changedMeanwhile(output) }
        let provider = NEFilterProviderConfiguration()
        provider.filterSockets = true
        provider.filterPackets = false
        provider.filterDataProviderBundleIdentifier = BlackiceIdentifiers.filter
        do {
            provider.vendorConfiguration = try candidate.vendorConfiguration()
        } catch {
            output.stderr("blackice start: cannot encode the configuration: \(error)")
            return ExitCode.software
        }
        manager.providerConfiguration = provider
        manager.localizedDescription = "blackice"
        manager.isEnabled = true
        guard save(manager, output) else { return ExitCode.software }
        output.stdout("Filter saved and enabled: \(candidate.summary).")
        output.stdout("This command does not verify enforcement; docs/phase-0.md has the check.")
        return ExitCode.success
    }

    public func stop(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().stop(output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        if let owner = saved.foreignOwner { return refuseForeign(owner, output) }
        guard confirm(.stop, output) else { return ExitCode.noPermission }
        guard let (manager, current) = loadSaved(output) else { return ExitCode.software }
        if let owner = current.foreignOwner { return refuseForeign(owner, output) }
        if current.providerBundleID != nil {
            manager.isEnabled = false
            guard save(manager, output) else { return ExitCode.software }
            output.stdout("Filter disabled.")
            guard remove(manager, output) else { return ExitCode.software }
            output.stdout("Filter configuration removed.")
        }
        return runExtensionRequest(
            OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: BlackiceIdentifiers.filter, queue: .main),
            output, deactivating: true)
    }

    public func status(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().status(output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        if let owner = saved.foreignOwner {
            output.stdout("filter: configured by another product (\(owner)); blackice leaves it alone")
            return ExitCode.success
        }
        guard saved.providerBundleID != nil else {
            output.stdout("filter: not configured (run blackice start)")
            return ExitCode.success
        }
        output.stdout("filter: \(saved.enabled ? "enabled" : "disabled")")
        output.stdout("configuration: \(saved.configuration?.summary ?? "unreadable")")
        output.stdout("enforcement: not verified by this command")
        return ExitCode.success
    }

    public func setMode(_ mode: Mode, output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().setMode(mode, output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        if let owner = saved.foreignOwner { return refuseForeign(owner, output) }
        guard let existing = saved.configuration else {
            output.stderr("blackice mode: blackice is not started, or its saved configuration is unreadable; run blackice start")
            return ExitCode.unavailable
        }
        if existing.mode == mode {
            output.stdout("Already in \(mode.rawValue) (generation \(existing.generation)).")
            return ExitCode.success
        }
        let candidate: ProviderConfiguration
        do {
            candidate = try existing.with(mode: mode)
        } catch {
            output.stderr("blackice mode: \(error)")
            return ExitCode.software
        }
        guard confirm(.mode(from: existing.mode, to: mode, generation: candidate.generation), output) else {
            return ExitCode.noPermission
        }
        guard let (manager, current) = loadSaved(output) else { return ExitCode.software }
        guard current.configuration == existing, current.foreignOwner == nil,
              let provider = manager.providerConfiguration else { return changedMeanwhile(output) }
        do {
            provider.vendorConfiguration = try candidate.vendorConfiguration()
        } catch {
            output.stderr("blackice mode: cannot encode the configuration: \(error)")
            return ExitCode.software
        }
        manager.providerConfiguration = provider
        guard save(manager, output) else { return ExitCode.software }
        output.stdout("Mode saved: \(candidate.summary).")
        return ExitCode.success
    }

    // MARK: - Ask mode over XPC (phase 2, compiled only)

    public func pending(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().pending(output: output)
        }
        do {
            let reply = try FilterClient(teamID: teamID).pending()
            CLI.pendingLines(reply).forEach(output.stdout)
            return ExitCode.success
        } catch {
            output.stderr("blackice pending: \(error)")
            return ExitCode.unavailable
        }
    }

    /// With the event's token the request goes as is: the extension checks the token. Without
    /// one, a person confirms with Touch ID first, and the extension trusts that claim only because
    /// the connection's code signing requirement proves it comes from this signed binary.
    public func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 {
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().answer(request, output: output)
        }
        let command = "blackice \(request.kind.rawValue)"
        if request.authorization == .touchID {
            guard let identity = request.identity else { return ExitCode.usage }
            let action: ControlAction = request.kind == .approve
                ? .approve(identity, host: request.host, seconds: request.seconds ?? 0)
                : .deny(identity, host: request.host)
            guard confirm(action, output) else { return ExitCode.noPermission }
        }
        do {
            let reply = try FilterClient(teamID: teamID).answer(request)
            if reply.status == .done { output.stdout(reply.message) } else { output.stderr("\(command): \(reply.message)") }
            return CLI.answerStatus(reply)
        } catch {
            output.stderr("\(command): \(error)")
            return ExitCode.unavailable
        }
    }

    /// Runs until the connection to the extension ends, then exits with 75 so launchd starts the
    /// daemon again (KeepAlive with SuccessfulExit false) and it registers anew. The hooks and
    /// their timeout come from the extension; the home, the temporary directory and the hooks'
    /// environment come from the user database and confstr, not from this process's environment.
    public func runDaemon(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().runDaemon(output: output)
        }
        let log: EventLog
        let runner: HookRunner
        do {
            let account = try UserAccount.current()
            log = try EventLog(url: DaemonPaths.eventLog(home: account.homeURL))
            runner = try HookRunner(options: .init(
                workDirectory: DaemonPaths.hookDirectory(temporary: account.temporaryURL),
                environment: HookRunner.environment(for: account)))
        } catch {
            output.stderr("blackice daemon: \(error)")
            return ExitCode.software
        }
        let daemon = Daemon(log: log, runner: runner)
        let intake = XPCEventIntake(teamID: teamID,
                                    onVerdict: { eventID, verdict in daemon.recordVerdict(eventID: eventID, verdict) },
                                    report: { line in FileHandle.standardError.write(Data("blackice daemon: \(line)\n".utf8)) })
        output.stdout("blackice daemon: event log \(log.url.path)")
        let finished = DispatchSemaphore(value: 0)
        Task {
            await daemon.run(intake)
            finished.signal()
        }
        finished.wait()
        output.stderr("blackice daemon: the connection to the network extension ended; exiting so launchd restarts it")
        return ExitCode.tempFail
    }

    // MARK: - The daemon's LaunchAgent (no Touch ID, no signature check beyond the bundle path)

    public func installAgent(output: SystemOutput) -> Int32 { AgentCommands.live.install(output: output) }
    public func uninstallAgent(output: SystemOutput) -> Int32 { AgentCommands.live.uninstall(output: output) }

    // MARK: - Pieces

    /// This process is Blackice.app's own executable, signed with a Developer ID for the
    /// blackice App ID. Anything else cannot activate the extension, so it is told so plainly.
    static func isSignedHost() -> Bool {
        guard Bundle.main.bundleIdentifier == BlackiceIdentifiers.host,
              let identity = CodeIdentity.current(), identity.teamID != nil,
              identity.signingID == BlackiceIdentifiers.host else { return false }
        return true
    }

    private func refuseForeign(_ owner: String, _ output: SystemOutput) -> Int32 {
        output.stderr("blackice: the content filter preference belongs to another product (\(owner)); blackice will not change it")
        return ExitCode.unavailable
    }

    private func changedMeanwhile(_ output: SystemOutput) -> Int32 {
        output.stderr("blackice: the saved configuration changed while waiting; nothing was saved, run the command again")
        return ExitCode.tempFail
    }

    /// Fresh Touch ID (or the login password) for this one change. No reuse window.
    private func confirm(_ action: ControlAction, _ output: SystemOutput) -> Bool {
        output.stdout(action.reason)
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            output.stderr("blackice: this Mac cannot ask for Touch ID or the login password; nothing changed")
            return false
        }
        let result = Completion()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: action.reason) { success, _ in
            result.finish(success ? 0 : 1)
        }
        let approved = MainLoop.wait(for: result, timeout: 120) == 0
        context.invalidate()
        if !approved { output.stderr("blackice: Touch ID was cancelled or failed; nothing changed") }
        return approved
    }

    private func loadSaved(_ output: SystemOutput) -> (NEFilterManager, SavedFilter)? {
        let manager = NEFilterManager.shared()
        let result = Completion()
        manager.loadFromPreferences { error in result.finish(error == nil ? 0 : 1) }
        guard MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0 else {
            output.stderr("blackice: cannot load the content filter preference")
            return nil
        }
        let provider = manager.providerConfiguration
        let configuration = try? ProviderConfiguration(vendorConfiguration: provider?.vendorConfiguration)
        return (manager, SavedFilter(providerBundleID: provider?.filterDataProviderBundleIdentifier,
                                     enabled: manager.isEnabled, configuration: configuration))
    }

    private func save(_ manager: NEFilterManager, _ output: SystemOutput) -> Bool {
        let result = Completion()
        manager.saveToPreferences { error in result.finish(error == nil ? 0 : 1) }
        let saved = MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0
        if !saved { output.stderr("blackice: saving the content filter preference failed") }
        return saved
    }

    private func remove(_ manager: NEFilterManager, _ output: SystemOutput) -> Bool {
        let result = Completion()
        manager.removeFromPreferences { error in result.finish(error == nil ? 0 : 1) }
        let removed = MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0
        if !removed { output.stderr("blackice: removing the content filter preference failed") }
        return removed
    }

    private func runExtensionRequest(_ request: OSSystemExtensionRequest, _ output: SystemOutput,
                                     deactivating: Bool = false) -> Int32 {
        let result = Completion()
        let delegate = ExtensionRequestDelegate(result: result, output: output, deactivating: deactivating)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        let status = withExtendedLifetime(delegate) { MainLoop.wait(for: result, timeout: Self.extensionRequestTimeout) }
        guard let status else {
            output.stderr("blackice: the system extension request did not finish in time; check System Settings before retrying")
            return ExitCode.software
        }
        return status
    }
}

/// A result set once, from any thread.
final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    func finish(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = status }
    }

    var status: Int32? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

enum MainLoop {
    /// Runs the main run loop (where NetworkExtension and SystemExtensions call back) until the
    /// completion is set or the timeout passes. nil on timeout.
    static func wait(for completion: Completion, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while completion.status == nil && Date() < deadline {
            if !RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return completion.status
    }
}

final class ExtensionRequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let result: Completion
    private let output: SystemOutput
    private let deactivating: Bool

    init(result: Completion, output: SystemOutput, deactivating: Bool) {
        self.result = result
        self.output = output
        self.deactivating = deactivating
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        output.stdout("Waiting for approval: open System Settings and allow the blackice network extension " +
                      "(General > Login Items & Extensions > Network Extensions).")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension candidate: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard ExtensionReplacement.allowed(existingID: existing.bundleIdentifier, existingVersion: existing.bundleVersion,
                                           candidateID: candidate.bundleIdentifier, candidateVersion: candidate.bundleVersion) else {
            output.stderr("blackice: refusing to replace extension version \(existing.bundleVersion) with older " +
                          "\(candidate.bundleVersion); to roll back on purpose run blackice stop, then start")
            return .cancel
        }
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .completed {
            output.stdout(deactivating ? "Network extension deactivated." : "Network extension activated.")
            self.result.finish(ExitCode.success)
        } else {
            output.stderr("blackice: macOS will finish the system extension request after a restart")
            self.result.finish(ExitCode.tempFail)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let error = error as NSError
        // Stopping something that was never activated (a start that failed early) is not a failure.
        if deactivating, error.domain == OSSystemExtensionErrorDomain,
           error.code == OSSystemExtensionError.Code.extensionNotFound.rawValue {
            output.stdout("The network extension was not installed.")
            result.finish(ExitCode.success)
            return
        }
        output.stderr("blackice: the system extension request failed (\(error.domain) \(error.code): " +
                      "\(error.localizedDescription))")
        result.finish(ExitCode.software)
    }
}
