/// Bundle identifiers, App IDs and names shared by the app, the extension and the scripts.
/// macos/scripts/sign.sh and the Info.plists in macos/Resources use the same values.
public enum BlackiceIdentifiers {
    /// Blackice.app, the host that runs the CLI and activates the extension.
    public static let host = "com.valentorassa.blackice"
    /// The network extension (NEFilterDataProvider).
    public static let filter = "com.valentorassa.blackice.filter"
    /// Unified logging subsystem of the extension.
    public static let logSubsystem = "com.valentorassa.blackice.filter"
    /// Signing identifier of the probe binary the phase 0 test builds.
    public static let probe = "com.valentorassa.blackice.probe"
    /// Objective-C name of the provider class, as NEProviderClasses names it in Filter-Info.plist.
    public static let providerClass = "BlackiceFilterDataProvider"
}
