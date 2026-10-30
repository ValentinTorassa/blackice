import Foundation
import LocalAuthentication

enum HostAction: String, CaseIterable {
    case activate, enable, disable, removeConfiguration = "remove-config", deactivate
    var reason: String {
        switch self {
        case .activate: return "Blackice: activate the app filter extension"
        case .enable: return "Blackice: enable or replace app filtering policy"
        case .disable: return "Blackice: turn off app filtering"
        case .removeConfiguration: return "Blackice: remove app filtering policy"
        case .deactivate: return "Blackice: deactivate the app filter extension"
        }
    }
}

/// New context per operation, no cached authorization or environment/CLI bypass.
/// Tests inject a denying authenticator into the gate, never into the host CLI.
protocol PresenceAuthenticating {
    func authenticate(reason: String, completion: @escaping (Bool) -> Void)
}

struct SystemPresenceAuthenticator: PresenceAuthenticating {
    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            context.invalidate(); completion(false); return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            context.invalidate()
            completion(success)
        }
    }
}

enum PresenceGate {
    static func perform(_ action: HostAction, using authenticator: PresenceAuthenticating,
                        denied: @escaping () -> Void, authorized: @escaping () -> Void) {
        authenticator.authenticate(reason: action.reason) { success in
            if success { authorized() } else { denied() }
        }
    }
}

enum ConfigurationUpdate {
    static func validate(_ candidate: AppConfiguration, replacing current: AppConfiguration?) throws {
        if let current, candidate.generation <= current.generation {
            throw ConfigurationError.invalid("update_requires_higher_generation")
        }
    }
}
