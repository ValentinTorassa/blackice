/// Bundle identifiers, App IDs and names shared by the app, the extension and the scripts.
/// macos/scripts/sign.sh and the Info.plists in macos/Resources use the same values.
public enum NetshieldIdentifiers {
    /// Netshield.app, the host that runs the CLI and activates the extension.
    public static let host = "com.valentorassa.netshield"
    /// The network extension (NEFilterDataProvider).
    public static let filter = "com.valentorassa.netshield.filter"
    /// Unified logging subsystem of the extension.
    public static let logSubsystem = "com.valentorassa.netshield.filter"
    /// Signing identifier of the probe binary the phase 0 test builds.
    public static let probe = "com.valentorassa.netshield.probe"
    /// Objective-C name of the provider class, as NEProviderClasses names it in Filter-Info.plist.
    public static let providerClass = "NetshieldFilterDataProvider"
}
