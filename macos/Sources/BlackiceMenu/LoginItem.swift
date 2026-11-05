import Foundation
import ServiceManagement

/// Open at Login, through SMAppService.mainApp (macOS 13 and later): the app registers itself, and
/// System Settings › General › Login Items lists it as Blackice, where the person can turn it off
/// too. At login, LaunchServices opens the app with no arguments, so it starts as the menu bar app
/// (MenuLaunch).
enum LoginItem {
    /// Why this copy cannot open at login, or nil.
    static var unavailableReason: String? {
        LoginItemCheck.unavailableReason(bundlePath: Bundle.main.bundleURL.path, bundleID: Bundle.main.bundleIdentifier,
                                         signed: SystemAdapter.isSignedApp)
    }

    static var state: LoginState {
        if let reason = unavailableReason { return .unavailable(reason) }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
