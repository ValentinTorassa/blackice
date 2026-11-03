// Who may talk to whom over XPC (phase 2). The extension listens on its Mach service; the CLI
// and the daemon, both the blackice binary inside Blackice.app, connect to it. Each side sets
// the other's code signing requirement on the connection, and NSXPCConnection checks it on every
// message, not only when the connection opens. Only code signed by the same team with the exact
// signing identifier passes. Values go into requirement strings, so they are validated first.

public enum Peers {
    /// The Mach service the extension listens on: NEMachServiceName in Filter-Info.plist, which
    /// scripts/sign.sh fills in with the Team ID. It must be prefixed by the app group.
    public static func machServiceName(teamID: String) -> String? {
        guard validTeamID(teamID) else { return nil }
        return teamID + "." + BlackiceIdentifiers.filter
    }

    /// What the extension requires of a client: Blackice.app's executable, our team.
    public static func clientRequirement(teamID: String) -> String? {
        requirement(BlackiceIdentifiers.host, teamID: teamID)
    }

    /// What the CLI and the daemon require of the extension.
    public static func filterRequirement(teamID: String) -> String? {
        requirement(BlackiceIdentifiers.filter, teamID: teamID)
    }

    private static func requirement(_ identifier: String, teamID: String) -> String? {
        guard validSigningID(identifier), validTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
