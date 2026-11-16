import Darwin
import Foundation
import BlackiceCore

/// How this process was started: opened as an app, or run as a command.
public enum MenuLaunch {
    /// Opened as an app: from Finder, Spotlight, `open` or as a login item. LaunchServices starts an
    /// app as a child of launchd with no arguments (older macOS versions added one `-psn_…`), and
    /// with no terminal on standard input, output or error. A command typed in a terminal has a
    /// shell for its parent and the terminal on all three; the daemon's LaunchAgent passes `daemon`
    /// and hooks pass `approve` or `deny`. So `blackice` with no arguments in a terminal still
    /// prints the usage. Only an app bundle is opened this way, so a build outside one never is.
    public static func opensAsApp(arguments: [String], parentPID: pid_t, terminal: Bool, inAppBundle: Bool) -> Bool {
        arguments.allSatisfy { $0.hasPrefix("-psn_") } && parentPID == 1 && !terminal && inAppBundle
    }

    /// The same for this process.
    public static func opensAsApp(arguments: [String]) -> Bool {
        opensAsApp(arguments: arguments, parentPID: getppid(),
                   terminal: [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains { isatty($0) == 1 },
                   inAppBundle: Bundle.main.bundleURL.pathExtension == "app")
    }
}

/// Keeps a second menu bar app from starting: the first one holds an exclusive flock(2) on a file
/// in the user's temporary directory for as long as it runs, and the kernel lets go when the
/// process ends, however it ends.
public final class MenuInstanceLock {
    private let descriptor: Int32

    /// Takes the lock, or returns nil when another process holds it.
    public init?(url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileSafetyError(url.path, "cannot open the lock file: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw FileSafetyError(url.path, "cannot lock the file: \(String(cString: strerror(code)))")
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// Writes the build this menu bar app runs into the lock file, where `blackice start` reads it.
    public func record(build: String) {
        let line = Array("build \(build)\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = line.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    /// Lets the lock go before this process ends, so that a new copy can take it.
    public func release() {
        _ = flock(descriptor, LOCK_UN)
    }

    /// The build a running menu bar app wrote into the lock file; nil when none did, as before
    /// 0.4.1, or the file cannot be read.
    public static func recordedBuild(url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("build ") else { return nil }
        let build = String(line.dropFirst("build ".count))
        return build.isEmpty ? nil : build
    }

    /// Whether a menu bar app holds the lock now. false when the file cannot be locked at all:
    /// starting the app then says why.
    public static func isHeld(url: URL) -> Bool {
        do {
            return try MenuInstanceLock(url: url) == nil
        } catch {
            return false
        }
    }

    /// blackice-menu.lock in the user's own temporary directory.
    public static func defaultURL() throws -> URL {
        try UserAccount.current().temporaryURL.appendingPathComponent("blackice-menu.lock")
    }
}

/// A menu bar app left running from another build. Each build of the extension listens on an XPC
/// service named after its build, so a menu bar app from before an upgrade cannot reach the new
/// one: it stays "Not reachable" until it is opened again.
public enum MenuUpgrade: Equatable, Sendable {
    case stay, reopen, quit

    /// Checks in a row that find no Blackice.app before the menu bar app quits: replacing the app
    /// leaves no bundle there for a moment.
    public static let quitAfter = 3

    /// The menu bar app's own check. `running`: the build it started from; `installed`: the
    /// build of the Blackice.app on disk now, nil when there is none to read; `missing`: the
    /// checks in a row that found none; `quarantined`: whether the app on disk is in quarantine
    /// (`quarantined(_:)`), asked only when it is another build. Another build there means an
    /// upgrade (or a rollback): open that one. No app for a while means it was removed: quit.
    ///
    /// Another build in quarantine is not opened: quit, and `blackice start`, which every upgrade
    /// needs, opens the menu bar app. Homebrew puts every app it installs in quarantine, macOS
    /// asks before the first opening of such an app, and an app opened in the background cannot
    /// be asked about. On 16 November 2026, right after a `brew upgrade` to 1.1.0, the menu bar
    /// app of 1.0.8 opened the new one: macOS could not show its question ("Prompt could not be
    /// shown"), killed the app it had opened, and with it the `blackice status` started 0.3 s
    /// before, which ended with "Killed: 9" (evidence P5-24, result 11). After a command of the
    /// new app has run, macOS opened the app with no question, which is how `start` opens it.
    public static func decide(running: String?, installed: String?, missing: Int,
                              quarantined: @autoclosure () -> Bool) -> MenuUpgrade {
        guard let running else { return .stay }
        guard let installed else { return missing >= quitAfter ? .quit : .stay }
        guard installed != running else { return .stay }
        return quarantined() ? .quit : .reopen
    }

    /// The extended attribute macOS keeps on what was downloaded, until the user removes it.
    public static let quarantineAttribute = "com.apple.quarantine"

    /// Whether the app bundle at `url` is in quarantine: the bundle or its executable has the
    /// attribute. It stays on an app Homebrew installed after macOS has let it run (1.1.0 had
    /// "0181;…;Homebrew Cask;…" an hour and a half after its first start), so this says where the
    /// app came from, not whether macOS would ask. The install script's download has none.
    public static func quarantined(_ url: URL, attribute: String = quarantineAttribute) -> Bool {
        var paths = [url.path]
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        if let executable = info?["CFBundleExecutable"] as? String {
            paths.append(url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path)
        }
        return paths.contains { getxattr($0, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    /// `blackice start`'s check: whether the menu bar app that holds the lock runs another build
    /// than this one. One from before 0.4.1 wrote no build, and is from before.
    public static func outdated(recorded: String?, own: String?) -> Bool {
        guard let own else { return false }
        return recorded != own
    }

    /// CFBundleVersion of the app bundle at `url` as it is on disk now; Bundle keeps the one it
    /// read at launch.
    public static func installedBuild(_ url: URL) -> String? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleVersion"] as? String
    }
}
