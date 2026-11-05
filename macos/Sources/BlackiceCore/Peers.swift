// Who may talk to whom over XPC (phase 2). The extension listens on its Mach service; the CLI
// and the daemon, both the blackice binary inside Blackice.app, connect to it. Each side sets
// the other's code signing requirement on the connection, and NSXPCConnection checks it on every
// message, not only when the connection opens. Only code signed by the same team with the exact
// signing identifier passes. Values go into requirement strings, so they are validated first.
import Foundation

public enum Peers {
    /// The extension's Info.plist inside Blackice.app, relative to the app bundle.
    public static let embeddedExtensionInfo = "Contents/Library/SystemExtensions/" + BlackiceIdentifiers.filter +
        ".systemextension/Contents/Info.plist"

    /// The Mach service a build of the extension listens on: NEMachServiceName in Filter-Info.plist,
    /// which scripts/sign.sh fills in with the Team ID and the build's CFBundleVersion. It must be
    /// prefixed by the app group. Each build has its own name: nesessionmanager runs each version
    /// of the extension as its own launchd job, and while the replaced version's process exits,
    /// launchd still holds its name and refuses it to the new job.
    public static func machServiceName(teamID: String, build: String) -> String? {
        guard validTeamID(teamID), validBuild(build) else { return nil }
        return teamID + "." + BlackiceIdentifiers.filter + "." + build
    }

    /// NEMachServiceName from an extension's Info.plist, when it is the name of that build
    /// (CFBundleVersion) for `teamID`; nil otherwise. The extension checks its own Info.plist with
    /// it, and the CLI and the daemon the Info.plist of the extension inside their app, so both
    /// sides take the name from the same file.
    public static func machServiceName(teamID: String, extensionInfo info: [String: Any]) -> String? {
        guard let build = info["CFBundleVersion"] as? String,
              let expected = machServiceName(teamID: teamID, build: build),
              let network = info["NetworkExtension"] as? [String: Any],
              network["NEMachServiceName"] as? String == expected else { return nil }
        return expected
    }

    /// The Mach service of the extension inside the app at `app` (Blackice.app), from its
    /// Info.plist. The extension macOS runs listens on this name only once `blackice start` has
    /// activated that build.
    public static func machServiceName(teamID: String, app: URL) -> String? {
        guard let info = extensionInfo(app: app) else { return nil }
        return machServiceName(teamID: teamID, extensionInfo: info)
    }

    /// CFBundleVersion of the extension inside the app at `app`.
    public static func extensionBuild(app: URL) -> String? {
        guard let build = extensionInfo(app: app)?["CFBundleVersion"] as? String, validBuild(build) else { return nil }
        return build
    }

    /// What the extension requires of a client: Blackice.app's executable, our team.
    public static func clientRequirement(teamID: String) -> String? {
        requirement(BlackiceIdentifiers.host, teamID: teamID)
    }

    /// What the CLI and the daemon require of the extension.
    public static func filterRequirement(teamID: String) -> String? {
        requirement(BlackiceIdentifiers.filter, teamID: teamID)
    }

    /// A build number as scripts/build-app.sh sets it: a positive whole number of at most 9 digits.
    static func validBuild(_ text: String) -> Bool {
        (1...9).contains(text.utf8.count) && text.utf8.first != 48 && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func extensionInfo(app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent(embeddedExtensionInfo)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func requirement(_ identifier: String, teamID: String) -> String? {
        guard validSigningID(identifier), validTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
