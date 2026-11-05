import Foundation
import BlackiceCore

/// Text that someone else chose, made fit for one menu line. App names, paths and hosts come from
/// whoever opens the connection, and the event log can be written by any program of the user, so
/// nothing from them reaches the menu as it is.
public enum MenuText {
    public static let appLimit = 48
    public static let hostLimit = 60
    public static let lineLimit = 72

    /// Control characters and line breaks become spaces; format characters (bidi overrides and
    /// isolates, zero-width marks), private-use and unassigned code points are dropped, and so are
    /// combining marks after the second in a row. Runs of spaces collapse. At most `limit`
    /// characters: the head is kept, or the tail with `keepTail` (for host names, where the end
    /// is the part that names the owner), and "…" marks the cut.
    public static func clean(_ text: String, limit: Int, keepTail: Bool = false) -> String {
        var kept = String.UnicodeScalarView()
        var space = false
        var marks = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !space, !kept.isEmpty { kept.append(" ") }
                space = true
                marks = 0
                continue
            case .format, .privateUse, .surrogate, .unassigned:
                continue
            case .nonspacingMark, .enclosingMark, .spacingMark:
                marks += 1
                if marks > 2 { continue }
            default:
                marks = 0
            }
            kept.append(scalar)
            space = false
        }
        var result = String(kept)
        while result.hasSuffix(" ") { result.removeLast() }
        guard limit > 1, result.count > limit else { return result }
        return keepTail ? "…" + String(result.suffix(limit - 1)) : String(result.prefix(limit - 1)) + "…"
    }

    public static func host(_ host: String) -> String { clean(host, limit: hostLimit, keepTail: true) }

    /// What to call the app: its outermost .app (or .systemextension) bundle in the path, so a
    /// helper counts for its app; else the path's last part; else the signing identifier, or
    /// "ad hoc code" for code named by its cdhash.
    public static func appName(path: String?, identity: AppIdentity?) -> String {
        if let path, !path.isEmpty {
            let parts = path.split(separator: "/")
            if let bundle = parts.first(where: { $0.hasSuffix(".app") || $0.hasSuffix(".systemextension") }) {
                let name = (String(bundle) as NSString).deletingPathExtension
                if !name.isEmpty { return clean(name, limit: appLimit) }
            }
            if let last = parts.last, !last.isEmpty { return clean(String(last), limit: appLimit) }
        }
        switch identity {
        case .signed(let signing)?: return clean(signing.signingID, limit: appLimit, keepTail: true)
        case .cdhash?: return "ad hoc code"
        case nil: return "unknown app"
        }
    }
}
