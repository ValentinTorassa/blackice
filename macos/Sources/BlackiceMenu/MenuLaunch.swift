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
