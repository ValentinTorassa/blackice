import Foundation
import BlackiceCore

/// What the menu knows about blackice at one moment. SystemAdapter reads it; MenuPresentation
/// words it. Plain values, so tests can build any state.
public struct MenuSnapshot: Equatable, Sendable {
    public enum Filter: Equatable, Sendable {
        /// Not read yet.
        case unknown
        /// This process is not Blackice.app signed with its Developer ID, so it cannot read the
        /// filter settings or reach the extension.
        case unsignedBuild
        /// No blackice filter is saved, or it is saved and turned off.
        case off
        /// Another product has this Mac's content filter.
        case foreign
        /// The filter settings cannot be read, or the configuration in them cannot.
        case unreadable
        /// On, in this mode, with this many hooks in the saved configuration.
        case on(Mode, hooks: Int)
    }

    public var filter: Filter
    /// What the extension answered to `pending`; nil when it did not answer or was not asked.
    public var pending: PendingReply?
    /// Whether launchd has the daemon's LaunchAgent loaded; nil when not checked yet.
    public var daemonRunning: Bool?
    /// The app is a newer build than the extension that runs: `blackice start` has not run since
    /// the app was upgraded in place.
    public var upgradeUnfinished: Bool
    /// When `pending` was read: the seconds left count down from there.
    public var readAt: Date

    public init(filter: Filter, pending: PendingReply? = nil, daemonRunning: Bool? = nil,
                upgradeUnfinished: Bool = false, readAt: Date = Date()) {
        self.filter = filter
        self.pending = pending
        self.daemonRunning = daemonRunning
        self.upgradeUnfinished = upgradeUnfinished
        self.readAt = readAt
    }

    /// The mode it filters in; nil when it is not on.
    public var mode: Mode? {
        if case .on(let mode, _) = filter { return mode }
        return nil
    }

    /// The extension answered over XPC.
    public var reachable: Bool { pending != nil }
}

extension MenuSnapshot.Filter {
    /// What the saved filter preference means, as `blackice status` reads it.
    public init(_ saved: SavedFilter) {
        if saved.foreignOwner != nil {
            self = .foreign
        } else if saved.providerBundleID == nil || !saved.enabled {
            self = .off
        } else if let configuration = saved.configuration {
            self = .on(configuration.mode, hooks: configuration.config.hooks.count)
        } else {
            self = .unreadable
        }
    }
}

/// How a mode change or a hand answer from the menu ended.
public enum MenuActionResult: Equatable, Sendable {
    case done
    /// Touch ID was cancelled: nothing changed, and nothing needs saying.
    case cancelled
    /// What the command printed to stderr, to show in an alert.
    case failed(String)
}

/// Whether the app is a newer build than the extension that runs. Builds compare as
/// CFBundleVersion does (ExtensionReplacement.version); an unparseable one compares as nothing.
public enum UpgradeCheck {
    public static func unfinished(appBuild: String?, runningBuilds: [String]) -> Bool {
        guard let appBuild, let app = ExtensionReplacement.version(appBuild) else { return false }
        let running = runningBuilds.compactMap(ExtensionReplacement.version)
        guard let newest = running.max(by: { $0.lexicographicallyPrecedes($1) }) else { return false }
        return newest.lexicographicallyPrecedes(app)
    }
}

/// Why this copy of blackice cannot open at login, or nil when it can. SMAppService.mainApp
/// registers the running app; System Settings lists it as Blackice only for the signed app, and
/// blackice runs only from /Applications.
public enum LoginItemCheck {
    public static func unavailableReason(bundlePath: String, bundleID: String?, signed: Bool) -> String? {
        guard bundlePath.hasSuffix(".app"), bundleID == BlackiceIdentifiers.host else {
            return "Only Blackice.app opens at login, not this build"
        }
        guard bundlePath == "/Applications/Blackice.app" else { return "Only for Blackice.app in /Applications" }
        guard signed else { return "Only for Blackice.app signed with its Developer ID" }
        return nil
    }
}
