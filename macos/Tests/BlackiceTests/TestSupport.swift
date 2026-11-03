import Darwin
import Foundation
@testable import BlackiceCore

/// A new 0700 directory under the temporary directory. Remove it with `removeTree`.
func makePrivateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blackice-test-" + UUID().uuidString, isDirectory: true)
    guard mkdir(url.path, 0o700) == 0 else { throw FileSafetyError(url.path, errnoText(errno)) }
    // realpath turns /var into /private/var, as `pwd -P` reports it. (URL.resolvingSymlinksInPath
    // goes the other way and drops /private.)
    guard let real = realpath(url.path, nil) else { throw FileSafetyError(url.path, errnoText(errno)) }
    defer { free(real) }
    return URL(fileURLWithPath: String(validatingCString: real) ?? url.path, isDirectory: true)
}

func removeTree(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

let testToken = "q8Zr0d3XyB1mVt5LkS9wJpQa2NcEf7HgUi4Ko6Rl0Ys"

func testEvent(host: String? = "example.com", id: String = "ev-0a1b2c3d", deadlineIn seconds: TimeInterval = 30) -> HookEvent {
    HookEvent(id: id, token: testToken,
              app: .init(signingID: "com.example.tool", teamID: "ABCDE12345", path: "/Applications/Tool.app"),
              host: host, ip: "203.0.113.7", port: 443, deadline: Date().addingTimeInterval(seconds))
}

func testRunner(_ directory: URL, limit: Int = 4, grace: TimeInterval = 0.3,
                environment: [String: String]? = nil) throws -> HookRunner {
    try HookRunner(options: .init(
        workDirectory: directory.appendingPathComponent("work", isDirectory: true),
        environment: environment ?? HookRunner.environment(from: ProcessInfo.processInfo.environment),
        maximumConcurrent: limit, gracePeriod: grace))
}

/// A path inside single quotes for a hook command line. Test paths never contain a quote.
func quotedPath(_ url: URL) -> String { "'" + url.path + "'" }

func permissions(_ url: URL) throws -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw FileSafetyError(url.path, errnoText(errno)) }
    return Int(info.st_mode & 0o777)
}

func fileExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// True when no process with this PID exists any more (zombies count as existing).
func processGone(_ pid: pid_t, within seconds: TimeInterval = 3) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        usleep(20_000)
    } while Date() < end
    return false
}

final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var items: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
