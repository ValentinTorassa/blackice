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

func testEvent(host: String? = "example.com", id: String = "ev-0a1b2c3d", deadlineIn seconds: TimeInterval = 30,
               app signingID: String = "com.example.tool") -> HookEvent {
    HookEvent(id: id, token: testToken,
              app: .init(signingID: signingID, teamID: "ABCDE12345", path: "/Applications/Tool.app"),
              host: host, ip: "203.0.113.7", port: 443, deadline: Date().addingTimeInterval(seconds))
}

func testRunner(_ directory: URL, limit: Int = 4, waiting: Int = 256, minimumStart: TimeInterval = 10,
                grace: TimeInterval = 0.3, environment: [String: String]? = nil) throws -> HookRunner {
    try HookRunner(options: .init(
        workDirectory: directory.appendingPathComponent("work", isDirectory: true),
        environment: environment ?? HookRunner.environment(for: try UserAccount.current()),
        maximumConcurrent: limit, maximumWaiting: waiting, minimumStartBudget: minimumStart, gracePeriod: grace))
}

/// Polls `condition` every 10 ms for up to `seconds`; true once it holds.
func eventually(within seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A made-up account for tests that must not depend on the real user.
func fakeAccount(home: String = "/Users/test", temporary: String = "/var/folders/xy/abc/T/") throws -> UserAccount {
    try UserAccount(uid: 501, name: "test", home: home, temporaryDirectory: temporary)
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
