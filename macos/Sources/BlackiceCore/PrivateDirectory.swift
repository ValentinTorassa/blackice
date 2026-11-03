import Darwin
import Foundation

/// A filesystem problem with a path blackice writes to: the event log, its directory, or the
/// directory where hooks get their event files.
public struct FileSafetyError: Error, Equatable, CustomStringConvertible, Sendable {
    public let path: String
    public let message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// Text for an errno value.
func errnoText(_ code: Int32) -> String { String(cString: strerror(code)) }

enum PrivateDirectory {
    /// Makes sure `url` is a directory that only the current user can enter: created with mode 0700
    /// when missing; when it exists it must be a real directory (not a symlink), owned by the
    /// current user, with no group or other permission bits. The parent must already exist.
    static func ensure(_ url: URL) throws {
        let path = url.path
        if mkdir(path, 0o700) == 0 {
            // The umask may have taken bits away, never added them; set the mode exactly anyway.
            guard chmod(path, 0o700) == 0 else { throw FileSafetyError(path, "cannot set mode 0700: \(errnoText(errno))") }
        } else if errno != EEXIST {
            throw FileSafetyError(path, "cannot create the directory: \(errnoText(errno))")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FileSafetyError(path, "cannot inspect the directory: \(errnoText(errno))") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw FileSafetyError(path, "is not a directory (a symlink is not accepted either)")
        }
        guard info.st_uid == geteuid() else { throw FileSafetyError(path, "is owned by another user") }
        guard (info.st_mode & 0o077) == 0 else {
            throw FileSafetyError(path, "must have mode 0700, but group or others have access")
        }
    }
}
