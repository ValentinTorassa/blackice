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
            candidate = try ProviderConfiguration.starting(configText: configText, after: saved.configuration,
                                                           keepingSwitches: !output.asWritten)
        } catch {
            output.stderr("blackice start: \(error)")
            return ExitCode.invalidConfig
        }
        if let file = try? BlackiceConfig(text: configText) { CLI.keptLines(candidate, file: file).forEach(output.stdout) }
        if output.setup { output.stdout(""); output.stdout(Style.heading("2 · Confirm with Touch ID")) }
        guard confirm(.start(candidate), output) else { return ExitCode.noPermission }

        let (activation, replaced, neededApproval, _) = runExtensionRequest(
            OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlackiceIdentifiers.filter, queue: .main),
            output)
        guard activation == ExitCode.success else { return activation }
        // After a replacement macOS starts the new build with the configuration saved before, and a
        // save made while it starts can miss it: on 5 November 2026 build 19 came up with generation
        // 17 and never saw the 18 saved a moment later. Wait until the new build answers first.
        if replaced { _ = Self.answers() }

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
        // A content filter saved for the first time (or again after stop removed it) makes macOS ask.
        let firstSave = current.providerBundleID == nil
        if firstSave { output.stdout((output.setup || neededApproval ? "  " : "") + ExtensionApproval.filterPrompt) }
        guard save(manager, output, firstSave: firstSave) else { return ExitCode.software }
        // The filter's process can come up seconds after the save, and macOS cuts the connections
        // open at that moment (on 3 November 2026 it cut fx's sign-in, started right after the
        // first start). Wait until it answers, so that what runs next does not lose its connection,
        // and until it names the configuration just saved: it keeps the one it has when it refuses
        // the new one, and saving says nothing about that.
        var inForce = Self.activation(of: candidate)
        // The new build still decides with the configuration from before the upgrade: turn the filter
        // off and on, so that it starts again with the one just saved.
        if replaced, case .other(let active) = inForce, (active?.generation ?? 0) < candidate.generation {
            output.stdout("Restarting the filter, which kept the configuration from before the upgrade…")
            manager.isEnabled = false
            guard save(manager, output) else { return ExitCode.software }
            manager.isEnabled = true
            guard save(manager, output) else { return ExitCode.software }
            inForce = Self.activation(of: candidate)
        }
        if replaced, inForce == .noAnswer {
            output.stderr("blackice was upgraded, and macOS needs a restart to finish. Restart the Mac, then run blackice start again.")
            output.stderr("Until then hooks, pending, approve and deny cannot reach the filter, and ask mode drops what it holds.")
            return ExitCode.tempFail
        }
        guard inForce == .active else {
            CLI.notActiveLines(candidate, inForce).forEach(output.stderr)
            return CLI.activationStatus(inForce)
        }
        // More setup follows: the caller says what happened.
        guard output.next else { return ExitCode.success }
        if neededApproval || output.setup { output.stdout("") }
        CLI.onLines(candidate).forEach(output.stdout)
        if neededApproval || output.setup {
            CLI.firstStartLines(candidate, daemonRunning: Self.daemonRunning()).forEach(output.stdout)
        }
        return ExitCode.success
    }

    /// Asks the extension which configuration it decides with until it names `candidate`, for up
    /// to `attempts` × `interval`: a newly launched extension takes a few seconds to listen, and a
    /// running one installs a change on its own queue. On 3 November 2026 an extension that
    /// replaced an older version in place had no Mach service until the Mac restarted
    /// (docs/install.md, "Upgrading").
    static func activation(of candidate: ProviderConfiguration, attempts: Int = 40, interval: TimeInterval = 0.5) -> Activation {
        guard let teamID = CodeIdentity.current()?.teamID else { return .noAnswer }
        var last = Activation.noAnswer
        for attempt in 1...attempts {
            if let reply = try? FilterClient(teamID: teamID).pending() {
                last = Activation(reply, saved: candidate)
                if last == .active { return last }
                // A newer generation: another change came after this one.
                if let active = reply.active, active.generation > candidate.generation { return last }
            }
            if attempt < attempts { Thread.sleep(forTimeInterval: interval) }
        }
        return last
    }

    /// Whether this build's extension answers within `attempts` × `interval`.
    static func answers(attempts: Int = 40, interval: TimeInterval = 0.5) -> Bool {
        guard let teamID = CodeIdentity.current()?.teamID else { return false }
        for attempt in 1...attempts {
            if (try? FilterClient(teamID: teamID).pending()) != nil { return true }
            if attempt < attempts { Thread.sleep(forTimeInterval: interval) }
        }
        return false
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
            guard remove(manager, output) else { return ExitCode.software }
        }
        let request = runExtensionRequest(
            OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: BlackiceIdentifiers.filter, queue: .main),
            output, deactivating: true)
        if request.status == ExitCode.success {
            output.stdout(Style.done("blackice is off" + (request.afterRestart ? "; macOS removes its extension at the next restart" : "")))
            if Self.daemonRunning() { output.stdout("  The daemon still runs: blackice agent uninstall") }
        } else if current.providerBundleID != nil {
            output.stderr("The filter is off, so connections are no longer checked; its extension is still installed.")
        }
        return request.status
    }

    public func status(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().status(output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        let filter: StatusReport.Filter
        if let owner = saved.foreignOwner {
            filter = .foreign(owner)
        } else if saved.providerBundleID == nil {
            filter = .notConfigured
        } else if !saved.enabled {
            filter = .disabled
        } else if let configuration = saved.configuration {
            filter = .on(configuration)
        } else {
            filter = .unreadable
        }
        var pending: PendingReply?
        var upgrade: UnfinishedUpgrade?
        if case .on = filter, let teamID = CodeIdentity.current()?.teamID {
            pending = try? FilterClient(teamID: teamID).pending()
            if pending == nil { upgrade = Self.unfinishedUpgrade() }
        }
        CLI.statusLines(StatusReport(filter: filter, daemonRunning: Self.daemonRunning(), pending: pending, upgrade: upgrade))
            .forEach(output.stdout)
        return ExitCode.success
    }

    public func runningMode() -> Mode? {
        guard Self.isSignedHost(), let (_, saved) = loadSaved(SystemOutput(stdout: { _ in }, stderr: { _ in })),
              saved.foreignOwner == nil, saved.providerBundleID != nil, saved.enabled else { return nil }
        return saved.configuration?.mode
    }

    /// Whether launchd has the daemon's LaunchAgent loaded for this user.
    public static func daemonRunning() -> Bool {
        LaunchAgent.run(["print", "gui/\(getuid())/\(LaunchAgent.label)"]).status == 0
    }

    /// Asked when the extension does not answer: whether macOS runs another build of it than the
    /// one inside this app, because the app was replaced and `blackice start` has not run since.
    /// One properties request to macOS; nil when it fails or the builds match.
    public static func unfinishedUpgrade() -> UnfinishedUpgrade? {
        let result = Completion()
        let delegate = ExtensionPropertiesDelegate(result: result)
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: BlackiceIdentifiers.filter,
                                                                 queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        let status = withExtendedLifetime(delegate) { MainLoop.wait(for: result, timeout: 5) }
        guard status == ExitCode.success else { return nil }
        return UnfinishedUpgrade(app: Peers.extensionBuild(app: Bundle.main.bundleURL), running: delegate.running)
    }

    public func setMode(_ mode: Mode, output: SystemOutput) -> Int32 {
        setMode(mode, answerer: nil, output: output)
    }

    /// `blackice mode`, and with `answerer` who answers in ask mode: `answers` in [agent] of the
    /// text blackice holds, not of the file, as the mode is.
    public func setMode(_ mode: Mode, answerer: Answerer?, output: SystemOutput) -> Int32 {
        guard Self.isSignedHost() else { return UnsignedSystem().setMode(mode, answerer: answerer, output: output) }
        guard let (_, saved) = loadSaved(output) else { return ExitCode.software }
        if let owner = saved.foreignOwner { return refuseForeign(owner, output) }
        guard let existing = saved.configuration else {
            output.stderr("blackice is off. Start it first: blackice start")
            return ExitCode.unavailable
        }
        if let answerer, let refusal = CLI.answererRefusal(answerer, config: existing.config) {
            output.stderr(refusal)
            return ExitCode.unavailable
        }
        let newAnswerer = answerer.flatMap { $0 == existing.config.answering.answerer ? nil : $0 }
        if existing.mode == mode, newAnswerer == nil {
            output.stdout(CLI.alreadyLine(existing))
            return ExitCode.success
        }
        let candidate: ProviderConfiguration
        do {
            candidate = try existing.with(mode: mode, answerer: newAnswerer)
        } catch {
            output.stderr("blackice mode: \(error)")
            return ExitCode.software
        }
        let action: ControlAction = newAnswerer.map { .answering($0, mode: mode, generation: candidate.generation) }
            ?? .mode(from: existing.mode, to: mode, generation: candidate.generation)
        guard confirm(action, output) else {
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
        let inForce = Self.activation(of: candidate)
        guard inForce == .active else {
            CLI.notActiveLines(candidate, inForce).forEach(output.stderr)
            return CLI.activationStatus(inForce)
        }
        CLI.modeChangedLines(candidate, daemonRunning: Self.daemonRunning()).forEach(output.stdout)
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
            output.stderr(Self.unfinishedUpgrade().map { "Cannot reach blackice's filter. " + $0.hint }
                ?? "Cannot reach blackice's filter (\(error)). Is it on? blackice status")
            return ExitCode.unavailable
        }
    }

    /// A person confirms with Touch ID first, and the extension trusts that claim only because the
    /// connection's code signing requirement proves it comes from this signed binary. Hooks do not
    /// come through here: the daemon sends their answers itself, with the event's token.
    public func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 {
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().answer(request, output: output)
        }
        let command = "blackice \(request.kind.rawValue)"
        guard request.authorization == .touchID, let identity = request.identity else { return ExitCode.usage }
        let action: ControlAction = request.kind == .approve
            ? .approve(identity, hosts: [request.host], seconds: request.seconds ?? 0, script: request.script)
            : .deny(identity, host: request.host, script: request.script)
        guard confirm(action, output) else { return ExitCode.noPermission }
        do {
            let reply = try FilterClient(teamID: teamID).answer(request)
            if reply.status == .done { output.stdout(Style.done(reply.message)) } else { output.stderr("\(command): \(reply.message)") }
            return CLI.answerStatus(reply)
        } catch {
            output.stderr(Self.unfinishedUpgrade().map { "\(command): cannot reach blackice's filter. " + $0.hint }
                ?? "\(command): cannot reach blackice's filter (\(error)). Is it on? blackice status")
            return ExitCode.unavailable
        }
    }

    /// `blackice deny --all`: a person confirms with Touch ID, then the extension forgets every
    /// approval. Trusted the way `answer` is.
    public func forgetApprovals(output: SystemOutput) -> Int32 {
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().forgetApprovals(output: output)
        }
        guard confirm(.forgetApprovals, output) else { return ExitCode.noPermission }
        do {
            let reply = try FilterClient(teamID: teamID).forget()
            if reply.status == .done { output.stdout(Style.done(reply.message)) } else { output.stderr("blackice deny: \(reply.message)") }
            return CLI.answerStatus(reply)
        } catch {
            output.stderr(Self.unfinishedUpgrade().map { "blackice deny: cannot reach blackice's filter. " + $0.hint }
                ?? "blackice deny: cannot reach blackice's filter (\(error)). Is it on? blackice status")
            return ExitCode.unavailable
        }
    }

    /// `blackice approve` with several hosts: one Touch ID whose dialog names every host, then one
    /// answer per host on the same connection. The extension trusts each the way it trusts one,
    /// because the connection comes from this signed binary. A host the extension refuses does not
    /// stop the others; the status is the first failure's.
    public func answer(all requests: [AnswerRequest], output: SystemOutput) -> Int32 {
        guard requests.count > 1 else { return requests.first.map { answer($0, output: output) } ?? ExitCode.usage }
        guard Self.isSignedHost(), let teamID = CodeIdentity.current()?.teamID else {
            return UnsignedSystem().answer(all: requests, output: output)
        }
        let first = requests[0]
        guard first.kind == .approve, let identity = first.identity, let seconds = first.seconds,
              requests.allSatisfy({ $0.kind == .approve && $0.authorization == .touchID && $0.identity == identity &&
                                    $0.seconds == seconds && $0.script == first.script }) else { return ExitCode.usage }
        guard confirm(.approve(identity, hosts: requests.map(\.host), seconds: seconds, script: first.script), output) else {
            return ExitCode.noPermission
        }
        var status = ExitCode.success
        do {
            let client = try FilterClient(teamID: teamID)
            for request in requests {
                let reply = try client.answer(request)
                if reply.status == .done { output.stdout(Style.done(reply.message)) } else { output.stderr("blackice approve: \(reply.message)") }
                if status == ExitCode.success { status = CLI.answerStatus(reply) }
            }
        } catch {
            output.stderr(Self.unfinishedUpgrade().map { "blackice approve: cannot reach blackice's filter. " + $0.hint }
                ?? "blackice approve: cannot reach blackice's filter (\(error)). Is it on? blackice status")
            return ExitCode.unavailable
        }
        return status
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
    public static func isSignedHost() -> Bool {
        guard Bundle.main.bundleIdentifier == BlackiceIdentifiers.host,
              let identity = CodeIdentity.current(), identity.teamID != nil,
              identity.signingID == BlackiceIdentifiers.host else { return false }
        return true
    }

    private func refuseForeign(_ owner: String, _ output: SystemOutput) -> Int32 {
        output.stderr("Another product (\(Describe.terminalSafe(owner))) has this Mac's content filter, so blackice will not change it.")
        return ExitCode.unavailable
    }

    private func changedMeanwhile(_ output: SystemOutput) -> Int32 {
        output.stderr("The saved configuration changed while you were confirming, so nothing was saved. Run the command again.")
        return ExitCode.tempFail
    }

    /// What `confirm` says when nothing was confirmed. A dialog nobody answers closes after 2
    /// minutes, and once said it was cancelled, which read like a press of Cancel. The menu shows
    /// none of them (SystemAdapter).
    public static let touchIDNoAnswer = "No answer to Touch ID within 2 minutes, so nothing changed."
    public static let touchIDCancelled = "Touch ID was cancelled, so nothing changed."
    public static let touchIDNotMatched = "Touch ID did not match, so nothing changed."

    /// The line for `confirm`'s outcome: nil when the time ran out, else LAError's code.
    static func notConfirmed(_ status: Int32?) -> String {
        switch status {
        case nil: return touchIDNoAnswer
        case Int32(LAError.Code.authenticationFailed.rawValue): return touchIDNotMatched
        default: return touchIDCancelled
        }
    }

    /// Fresh Touch ID (or the login password) for this one change. No reuse window.
    private func confirm(_ action: ControlAction, _ output: SystemOutput) -> Bool {
        if !output.setup { output.stdout("Touch ID to \(action.reason)…") }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            output.stderr("This Mac cannot ask for Touch ID or your login password, so nothing changed.")
            return false
        }
        let result = Completion()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: action.reason) { success, error in
            // LAError's codes are negative; 1 stands for an error that is none of them.
            result.finish(success ? 0 : (error as? LAError).map { Int32($0.errorCode) } ?? 1)
        }
        let status = MainLoop.wait(for: result, timeout: 120)
        context.invalidate()
        let approved = status == 0
        if !approved { output.stderr(Self.notConfirmed(status)) }
        if approved, output.setup { output.stdout("  " + Style.done("Confirmed")) }
        return approved
    }

    private func loadSaved(_ output: SystemOutput) -> (NEFilterManager, SavedFilter)? {
        let manager = NEFilterManager.shared()
        let result = Completion()
        manager.loadFromPreferences { error in result.finish(error == nil ? 0 : 1) }
        guard MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0 else {
            output.stderr("Cannot read this Mac's content filter settings. Try again in a moment.")
            return nil
        }
        let provider = manager.providerConfiguration
        let configuration = try? ProviderConfiguration(vendorConfiguration: provider?.vendorConfiguration)
        return (manager, SavedFilter(providerBundleID: provider?.filterDataProviderBundleIdentifier,
                                     enabled: manager.isEnabled, configuration: configuration))
    }

    private func save(_ manager: NEFilterManager, _ output: SystemOutput, firstSave: Bool = false) -> Bool {
        let result = Completion()
        manager.saveToPreferences { error in result.finish(error == nil ? 0 : 1) }
        let saved = MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0
        if !saved {
            output.stderr(firstSave
                ? "macOS did not save blackice's filter. If you clicked Don't Allow, run blackice start again and click Allow."
                : "Saving the content filter settings failed. Try again in a moment.")
        }
        return saved
    }

    private func remove(_ manager: NEFilterManager, _ output: SystemOutput) -> Bool {
        let result = Completion()
        manager.removeFromPreferences { error in result.finish(error == nil ? 0 : 1) }
        let removed = MainLoop.wait(for: result, timeout: Self.preferencesTimeout) == 0
        if !removed { output.stderr("Removing the content filter settings failed. Try again in a moment.") }
        return removed
    }

    /// The request's exit status, whether macOS replaced a running extension of another version,
    /// and whether it had to wait for the person to allow the extension.
    private func runExtensionRequest(_ request: OSSystemExtensionRequest, _ output: SystemOutput, deactivating: Bool = false)
        -> (status: Int32, replaced: Bool, neededApproval: Bool, afterRestart: Bool) {
        let result = Completion()
        let delegate = ExtensionRequestDelegate(result: result, output: output, deactivating: deactivating)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        let status = withExtendedLifetime(delegate) { MainLoop.wait(for: result, timeout: Self.extensionRequestTimeout) }
        guard let status else {
            output.stderr(deactivating
                ? "macOS did not finish removing the network extension in time. Run blackice stop again."
                : "Gave up waiting after 10 minutes. Allow the network extension as above, then run blackice start again.")
            return (ExitCode.software, delegate.replaced, delegate.neededApproval, delegate.afterRestart)
        }
        return (status, delegate.replaced, delegate.neededApproval, delegate.afterRestart)
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
    /// Set when macOS asked to replace a running extension of another version and we said yes.
    private(set) var replaced = false
    /// Set when macOS held the request until the person allowed the extension.
    private(set) var neededApproval = false
    /// Set when macOS finishes removing the extension at the next restart.
    private(set) var afterRestart = false

    init(result: Completion, output: SystemOutput, deactivating: Bool) {
        self.result = result
        self.output = output
        self.deactivating = deactivating
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        neededApproval = true
        if deactivating {
            output.stdout("macOS asks you to confirm removing the network extension: follow its dialog. Waiting up to 10 minutes…")
            return
        }
        ExtensionApproval.lines(macOS: SystemSettings.majorVersion, opened: SystemSettings.openExtensions(), setup: output.setup)
            .forEach(output.stdout)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension candidate: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard ExtensionReplacement.allowed(existingID: existing.bundleIdentifier, existingVersion: existing.bundleVersion,
                                           candidateID: candidate.bundleIdentifier, candidateVersion: candidate.bundleVersion) else {
            output.stderr("blackice: refusing to replace extension version \(existing.bundleVersion) with older " +
                          "\(candidate.bundleVersion); to roll back on purpose run blackice stop, then start")
            return .cancel
        }
        if existing.bundleVersion != candidate.bundleVersion { replaced = true }
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .completed {
            if !deactivating, neededApproval { output.stdout("  " + Style.done("Allowed")) }
            self.result.finish(ExitCode.success)
        } else if deactivating {
            afterRestart = true
            self.result.finish(ExitCode.success)
        } else {
            output.stderr("macOS finishes setting up the network extension at the next restart. Restart the Mac, " +
                          "then run blackice start again.")
            self.result.finish(ExitCode.tempFail)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let error = error as NSError
        // Stopping something that was never activated (a start that failed early) is not a failure.
        if deactivating, error.domain == OSSystemExtensionErrorDomain,
           error.code == OSSystemExtensionError.Code.extensionNotFound.rawValue {
            result.finish(ExitCode.success)
            return
        }
        output.stderr("macOS refused the network extension request: \(error.localizedDescription) " +
                      "(\(error.domain) \(error.code)).")
        result.finish(ExitCode.software)
    }
}

/// The builds of the extension that macOS has enabled and is not uninstalling, from a properties
/// request. Never asks the person and never replaces anything.
final class ExtensionPropertiesDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let result: Completion
    private(set) var running: [String] = []

    init(result: Completion) { self.result = result }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        running = properties.filter { $0.isEnabled && !$0.isUninstalling }.map(\.bundleVersion)
        result.finish(ExitCode.success)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension candidate: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .cancel
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        self.result.finish(ExitCode.success)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        result.finish(ExitCode.software)
    }
}

/// Opens System Settings where macOS lists the network extensions waiting for the person's OK.
enum SystemSettings {
    static var majorVersion: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// false when it could not be opened, for example with nobody logged in at the screen.
    static func openExtensions() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [ExtensionApproval.settingsURL(macOS: majorVersion)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
