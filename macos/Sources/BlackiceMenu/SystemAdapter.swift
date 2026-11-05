// Every call the menu makes into blackice's status, pending, mode, approve and deny is in this
// file; the rest of the menu sees MenuSnapshot and MenuActionResult only, so this is the one file
// to adapt when those commands change.
//
// Reading needs no Touch ID and follows what `blackice status` reads: the filter preference
// (NEFilterManager), the extension's pending list over XPC, with the configuration it decides
// with, whether launchd has the daemon, and, when the extension does not answer, which build of
// it macOS runs. Changing goes through NESystemControl, the same code as `blackice mode`,
// `blackice approve` and `blackice deny`, Touch ID included: the menu adds no privileged path of
// its own.
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
    /// `full`, it also checks whether the daemon runs; without, that is left nil. `upgrade` is
    /// left nil: `unfinishedUpgrade` asks for it.
    func read(full: Bool, completion: @escaping @MainActor (MenuSnapshot) -> Void) {
        guard Self.isSignedApp, let teamID = CodeIdentity.current()?.teamID else {
            completion(MenuSnapshot(filter: .unsignedBuild))
            return
        }
        Self.loadFilter { filter in
            DispatchQueue.global(qos: .utility).async {
                var snapshot = MenuSnapshot(filter: filter)
                // FilterClient reaches the service name of this app's own build of the extension.
                if case .on = filter { snapshot.pending = try? FilterClient(teamID: teamID).pending() }
                if full { snapshot.daemonRunning = NESystemControl.daemonRunning() }
                snapshot.readAt = Date()
                DispatchQueue.main.async { completion(snapshot) }
            }
        }
    }

    /// `blackice status`'s check when the extension does not answer: whether macOS still runs an
    /// older build of it than this app's. One properties request to macOS, waited for in the main
    /// run loop for up to 5 s (MainLoop.wait), so call it as `setMode` is.
    func unfinishedUpgrade() -> UnfinishedUpgrade? {
        Self.isSignedApp ? NESystemControl.unfinishedUpgrade() : nil
    }

    /// `blackice mode`: Touch ID, then the configuration saved in the new mode, then up to 20 s
    /// for the filter to name it; the lines of a filter that did not take it come back as
    /// `.failed`. NESystemControl runs the main run loop until it is done (MainLoop.wait), so call
    /// this on the main thread from a run loop callout, never from inside a block on the main
    /// dispatch queue, which the nested run loop would not drain.
    func setMode(_ mode: Mode) -> MenuActionResult {
        let output = CapturedOutput()
        return Self.result(NESystemControl().setMode(mode, output: output.system), output.errors)
    }

    /// `blackice approve --for` or `blackice deny`: Touch ID, then the answer over XPC. Hooks never
    /// come this way; the daemon sends theirs with the event's token. Called as `setMode` is.
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

    /// NESystemControl.isSignedHost: this process is Blackice.app's own executable, signed with a
    /// Developer ID for the blackice App ID.
    nonisolated static var isSignedApp: Bool { NESystemControl.isSignedHost() }
}

/// What a command printed, kept for the menu: stdout is dropped, stderr is shown when it failed.
private final class CapturedOutput {
    private(set) var errors: [String] = []

    var system: SystemOutput {
        SystemOutput(stdout: { _ in }, stderr: { [unowned self] in self.errors.append($0) })
    }
}
