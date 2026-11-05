// Every call the menu makes into blackice's status, pending, mode, approve and deny is in this
// file; the rest of the menu sees MenuSnapshot and MenuActionResult only. Other branches change
// those functions (the checks after start and mode, an upgrade hint, the hook token path), so
// this is the one file to adapt when they land.
//
// Reading needs no Touch ID and follows what `blackice status` reads: the filter preference
// (NEFilterManager), the extension's pending list over XPC, whether launchd has the daemon, and
// here also the build of the extension that runs. Changing goes through NESystemControl, the same
// code as `blackice mode` and as `blackice approve` or `deny` without a token, Touch ID included:
// the menu adds no privileged path of its own.
import Foundation
import BlackiceCLI
import BlackiceCore
import BlackiceSystem
import BlackiceXPC
import NetworkExtension

@MainActor
final class SystemAdapter {
    /// Reads a snapshot. Call on the main thread; `completion` runs on the main thread. The XPC
    /// call and launchctl run on a background queue, so the menu never waits for them. With
    /// `full`, it also checks whether the daemon runs and whether an upgrade is unfinished;
    /// without, those are left nil and false.
    func read(full: Bool, completion: @escaping @MainActor (MenuSnapshot) -> Void) {
        guard Self.isSignedApp, let teamID = CodeIdentity.current()?.teamID else {
            completion(MenuSnapshot(filter: .unsignedBuild))
            return
        }
        Self.loadFilter { filter in
            DispatchQueue.global(qos: .utility).async {
                var snapshot = MenuSnapshot(filter: filter)
                if case .on = filter { snapshot.pending = try? FilterClient(teamID: teamID).pending() }
                if full {
                    snapshot.daemonRunning = Self.daemonRunning()
                    snapshot.upgradeUnfinished = UpgradeCheck.unfinished(appBuild: Self.appBuild,
                                                                         runningBuilds: Self.runningExtensionBuilds())
                }
                snapshot.readAt = Date()
                DispatchQueue.main.async { completion(snapshot) }
            }
        }
    }

    /// `blackice mode`: Touch ID, then the configuration saved in the new mode. NESystemControl
    /// runs the main run loop until it is done (MainLoop.wait), so call this on the main thread
    /// from a run loop callout, never from inside a block on the main dispatch queue, which the
    /// nested run loop would not drain.
    func setMode(_ mode: Mode) -> MenuActionResult {
        let output = CapturedOutput()
        return Self.result(NESystemControl().setMode(mode, output: output.system), output.errors)
    }

    /// `blackice approve --for` or `blackice deny` without a token: Touch ID, then the answer over
    /// XPC. Called as `setMode` is.
    func answer(_ request: AnswerRequest) -> MenuActionResult {
        let output = CapturedOutput()
        return Self.result(NESystemControl().answer(request, output: output.system), output.errors)
    }

    /// NESystemControl.confirm's line when Touch ID is cancelled: nothing changed, nothing to show.
    nonisolated static let cancelledLine = "Touch ID was cancelled, so nothing changed."

    nonisolated static func result(_ status: Int32, _ errors: [String]) -> MenuActionResult {
        if status == ExitCode.success { return .done }
        if status == ExitCode.noPermission, errors.last == cancelledLine { return .cancelled }
        return .failed(errors.isEmpty ? "blackice stopped with status \(status)." : errors.joined(separator: "\n"))
    }

    /// The filter preference as NESystemControl.status reads it. NEFilterManager calls back on a
    /// queue of its own choosing, so nothing here assumes the main thread.
    nonisolated private static func loadFilter(_ done: @escaping @Sendable (MenuSnapshot.Filter) -> Void) {
        NEFilterManager.shared().loadFromPreferences { error in
            guard error == nil else { return done(.unreadable) }
            let manager = NEFilterManager.shared()
            let provider = manager.providerConfiguration
            let configuration = try? ProviderConfiguration(vendorConfiguration: provider?.vendorConfiguration)
            done(MenuSnapshot.Filter(SavedFilter(providerBundleID: provider?.filterDataProviderBundleIdentifier,
                                                 enabled: manager.isEnabled, configuration: configuration)))
        }
    }

    /// The same check as NESystemControl.isSignedHost: this process is Blackice.app's own
    /// executable, signed with a Developer ID for the blackice App ID.
    nonisolated static var isSignedApp: Bool {
        guard Bundle.main.bundleIdentifier == BlackiceIdentifiers.host, let identity = CodeIdentity.current(),
              identity.teamID != nil, identity.signingID == BlackiceIdentifiers.host else { return false }
        return true
    }

    /// As NESystemControl.daemonRunning: launchd has the daemon's LaunchAgent loaded for this user.
    nonisolated static func daemonRunning() -> Bool {
        LaunchAgent.run(["print", "gui/\(getuid())/\(LaunchAgent.label)"]).status == 0
    }

    nonisolated static var appBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    /// The CFBundleVersion of each copy of the filter extension that runs, from its bundle under
    /// /Library/SystemExtensions, found by its process's path. Cheap: one pass over the process
    /// list and a small plist per copy.
    nonisolated static func runningExtensionBuilds() -> [String] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let marker = "/" + BlackiceIdentifiers.filter + ".systemextension/"
        var builds: [String] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path.hasPrefix("/Library/SystemExtensions/"), let end = path.range(of: marker) else { continue }
            let info = String(path[..<end.upperBound]) + "Contents/Info.plist"
            if let build = NSDictionary(contentsOfFile: info)?["CFBundleVersion"] as? String { builds.append(build) }
        }
        return builds
    }
}

/// What a command printed, kept for the menu: stdout is dropped, stderr is shown when it failed.
private final class CapturedOutput {
    private(set) var errors: [String] = []

    var system: SystemOutput {
        SystemOutput(stdout: { _ in }, stderr: { [unowned self] in self.errors.append($0) })
    }
}
