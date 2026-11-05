import Foundation
import BlackiceCLI
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
        /// On, with this configuration saved (its generation, mode and digest) and this many hooks
        /// in it.
        case on(saved: ActiveConfiguration, hooks: Int)
    }

    public var filter: Filter
    /// What the extension answered to `pending`; nil when it did not answer or was not asked.
    public var pending: PendingReply?
    /// Whether launchd has the daemon's LaunchAgent loaded; nil when not checked yet.
    public var daemonRunning: Bool?
    /// Set when the extension does not answer because macOS still runs an older build of it than
    /// this app's: the app was replaced and `blackice start` has not run since.
    public var upgrade: UnfinishedUpgrade?
    /// When `pending` was read: the seconds left count down from there.
    public var readAt: Date

    public init(filter: Filter, pending: PendingReply? = nil, daemonRunning: Bool? = nil,
                upgrade: UnfinishedUpgrade? = nil, readAt: Date = Date()) {
        self.filter = filter
        self.pending = pending
        self.daemonRunning = daemonRunning
        self.upgrade = upgrade
        self.readAt = readAt
    }

    /// A blackice filter is saved and turned on.
    public var isOn: Bool {
        if case .on = filter { return true }
        return false
    }

    /// The mode the filter decides in: the one the extension reports as active when it answers,
    /// else the saved one. nil when it is not on, or answers that it holds no configuration.
    public var mode: Mode? {
        guard case .on(let saved, _) = filter else { return nil }
        guard let pending else { return saved.mode }
        return pending.active?.mode
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
            self = .on(saved: ActiveConfiguration(configuration), hooks: configuration.config.hooks.count)
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
