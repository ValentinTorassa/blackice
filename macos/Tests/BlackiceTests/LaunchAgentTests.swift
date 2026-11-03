import Darwin
import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore

// The daemon's LaunchAgent: the plist, the bundle check, and install/uninstall against a
// temporary home with a fake launchctl. Nothing here touches ~/Library or runs launchctl.

private let bundled = "/Applications/Blackice.app/Contents/MacOS/blackice"
private let service = "gui/501/com.valentorassa.blackice.daemon"

private func dictionary(_ data: Data) throws -> NSDictionary {
    try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
}

/// A fake launchctl that records its arguments and answers with `status(arguments)`.
private func fakeLaunchctl(_ calls: Recorder<[String]>,
                           status: @escaping ([String]) -> Int32 = { $0.first == "bootout" ? 3 : 0 }) -> ([String]) -> LaunchctlResult {
    { arguments in
        calls.append(arguments)
        let code = status(arguments)
        return LaunchctlResult(status: code, output: code == 0 ? "" : "Boot-out failed: \(code): Some error")
    }
}

private func installer(_ home: URL, _ calls: Recorder<[String]>,
                       status: @escaping ([String]) -> Int32 = { $0.first == "bootout" ? 3 : 0 }) throws -> LaunchAgentInstaller {
    LaunchAgentInstaller(account: try fakeAccount(home: home.path), launchctl: fakeLaunchctl(calls, status: status))
}

struct LaunchAgentPlistTests {
    @Test func theGeneratedPlistMatchesTheTemplate() throws {
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LaunchAgent/com.valentorassa.blackice.daemon.plist")
        var expected = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: template), format: nil)
            as? [String: Any])
        let logs = "/Users/test/Library/Logs/blackice"
        expected["ProgramArguments"] = (expected["ProgramArguments"] as? [String])?.map { $0 == "BLACKICE_BIN" ? bundled : $0 }
        for key in ["StandardOutPath", "StandardErrorPath"] {
            expected[key] = (expected[key] as? String)?.replacingOccurrences(of: "BLACKICE_LOGS", with: logs)
        }
        let generated = try dictionary(LaunchAgent.plist(binary: bundled, logDirectory: logs))
        #expect(generated == expected as NSDictionary)
        #expect(generated["ProgramArguments"] as? [String] == [bundled, "daemon"])
        #expect((generated["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(generated["ThrottleInterval"] as? Int == 10 && generated["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(generated["StandardErrorPath"] as? String == logs + "/daemon.err.log")
        #expect(generated["EnvironmentVariables"] == nil)
    }

    @Test func pathsAreEscapedAndChecked() throws {
        let odd = "/Users/a&b <c>/Blackice.app/Contents/MacOS/blackice"
        let generated = try dictionary(LaunchAgent.plist(binary: odd, logDirectory: "/Users/a&b <c>/Library/Logs/blackice/"))
        #expect(generated["ProgramArguments"] as? [String] == [odd, "daemon"])
        #expect(generated["StandardOutPath"] as? String == "/Users/a&b <c>/Library/Logs/blackice/daemon.out.log")
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.plist(binary: "blackice", logDirectory: "/tmp") }
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.plist(binary: bundled, logDirectory: "logs") }
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.plist(binary: bundled + "\n", logDirectory: "/tmp") }
        #expect(LaunchAgent.plistURL(home: URL(fileURLWithPath: "/Users/test", isDirectory: true)).path
            == "/Users/test/Library/LaunchAgents/com.valentorassa.blackice.daemon.plist")
    }

    @Test func onlyTheBinaryInsideBlackiceAppIsAccepted() {
        for path in [bundled, "/Users/test/Downloads/Blackice.app/Contents/MacOS/blackice", "/Blackice.app/Contents/MacOS/blackice"] {
            #expect((try? LaunchAgent.checkBundledBinary(path)) == path, "\(path)")
        }
        for path in ["/usr/local/bin/blackice", ".build/debug/blackice", "Blackice.app/Contents/MacOS/blackice",
                     "/Applications/Blackice.app/Contents/MacOS/blackice-filter", "/Applications/Other.app/Contents/MacOS/blackice",
                     "/Applications/Blackice.app/Contents/MacOS/../MacOS/blackice", "/Applications//Blackice.app/Contents/MacOS/blackice",
                     "/Applications/./Blackice.app/Contents/MacOS/blackice", "/Applications/Blackice.app/Contents/MacOS/blackice/",
                     "/Applications/blackice.app/Contents/MacOS/blackice", "/Apps\n/Blackice.app/Contents/MacOS/blackice", ""] {
            #expect(throws: LaunchAgentError.self, "\(path)") { try LaunchAgent.checkBundledBinary(path) }
        }
        // The test runner is not inside Blackice.app.
        let running = LaunchAgent.runningBinary()
        #expect(running?.hasPrefix("/") == true)
        #expect((try? LaunchAgent.checkBundledBinary(running ?? "")) == nil)
    }
}

struct LaunchAgentInstallerTests {
    @Test func installWritesThePlistAndBootstrapsIt() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        let lines = Recorder<String>()
        let agent = try installer(home, calls)
        try agent.install(binary: bundled, say: lines.append)

        let plist = home.appendingPathComponent("Library/LaunchAgents/com.valentorassa.blackice.daemon.plist")
        let logs = home.appendingPathComponent("Library/Logs/blackice")
        #expect(agent.plistURL.path == plist.path && agent.service == service && agent.domain == "gui/501")
        #expect(try Data(contentsOf: plist) == LaunchAgent.plist(binary: bundled, logDirectory: logs.path))
        #expect(try permissions(plist) == 0o644)
        #expect(try permissions(logs) == 0o700)
        #expect(calls.items == [["bootout", service], ["bootstrap", "gui/501", plist.path]])
        #expect(lines.items.first == "Wrote \(plist.path) for \(bundled).")

        // Again, as after moving the app: the loaded copy is booted out first, the file replaced.
        let moved = "/Users/test/Apps/Blackice.app/Contents/MacOS/blackice"
        try installer(home, calls, status: { _ in 0 }).install(binary: moved, say: { _ in })
        #expect(try dictionary(Data(contentsOf: plist))["ProgramArguments"] as? [String] == [moved, "daemon"])
        #expect(calls.items.suffix(2) == [["bootout", service], ["bootstrap", "gui/501", plist.path]])
    }

    @Test func aBinaryOutsideTheBundleTouchesNothing() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        #expect(throws: LaunchAgentError.self) { try installer(home, calls).install(binary: "/usr/local/bin/blackice", say: { _ in }) }
        #expect(calls.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func anOpenLogDirectoryIsRefusedBeforeLaunchctl() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let logs = home.appendingPathComponent("Library/Logs/blackice")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        #expect(chmod(logs.path, 0o755) == 0)
        let calls = Recorder<[String]>()
        #expect(throws: FileSafetyError.self) { try installer(home, calls).install(binary: bundled, say: { _ in }) }
        #expect(calls.items.isEmpty)
        #expect(!fileExists(home.appendingPathComponent("Library/LaunchAgents/com.valentorassa.blackice.daemon.plist")))
    }

    @Test func aFailedBootstrapIsReported() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        let agent = try installer(home, calls, status: { $0.first == "bootstrap" ? 5 : 0 })
        #expect(throws: LaunchAgentError("launchctl bootstrap gui/501 failed with status 5: Boot-out failed: 5: Some error")) {
            try agent.install(binary: bundled, say: { _ in })
        }
    }

    @Test func uninstallBootsOutAndRemovesThePlist() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        try installer(home, calls).install(binary: bundled, say: { _ in })
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.valentorassa.blackice.daemon.plist")

        let lines = Recorder<String>()
        try installer(home, calls, status: { _ in 0 }).uninstall(say: lines.append)
        #expect(calls.items.last == ["bootout", service])
        #expect(!fileExists(plist))
        #expect(lines.items == ["Stopped and unloaded com.valentorassa.blackice.daemon.", "Removed \(plist.path)."])

        // Not loaded and no file: still a success, and it says so.
        for status: Int32 in [3, 113] {
            let quiet = Recorder<String>()
            try installer(home, calls, status: { _ in status }).uninstall(say: quiet.append)
            #expect(quiet.items == ["com.valentorassa.blackice.daemon was not loaded.", "There was no \(plist.path)."])
        }
        // The log directory and the event log in it stay.
        #expect(fileExists(home.appendingPathComponent("Library/Logs/blackice")))
    }

    @Test func aFailedBootoutLeavesThePlist() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        try installer(home, calls).install(binary: bundled, say: { _ in })
        #expect(throws: LaunchAgentError.self) { try installer(home, calls, status: { _ in 5 }).uninstall(say: { _ in }) }
        #expect(fileExists(home.appendingPathComponent("Library/LaunchAgents/com.valentorassa.blackice.daemon.plist")))
    }
}

struct AgentCommandTests {
    private func run(_ commands: AgentCommands, install: Bool) -> (status: Int32, stdout: [String], stderr: [String]) {
        let out = Recorder<String>(), err = Recorder<String>()
        let output = SystemOutput(stdout: { out.append($0) }, stderr: { err.append($0) })
        let status = install ? commands.install(output: output) : commands.uninstall(output: output)
        return (status, out.items, err.items)
    }

    @Test func installOutsideTheBundleExitsWith69() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        let commands = AgentCommands(account: { try fakeAccount(home: home.path) }, binary: { "/usr/local/bin/blackice" },
                                     launchctl: fakeLaunchctl(calls))
        let result = run(commands, install: true)
        #expect(result.status == 69 && result.stdout.isEmpty)
        #expect(result.stderr.first?.hasPrefix("blackice agent install: this blackice is not inside Blackice.app") == true)
        #expect(calls.items.isEmpty)
        let unknown = run(AgentCommands(account: { try fakeAccount(home: home.path) }, binary: { nil },
                                        launchctl: fakeLaunchctl(calls)), install: true)
        #expect(unknown.status == 69 && calls.items.isEmpty)
    }

    @Test func installAndUninstallReportTheirStatus() throws {
        let home = try makePrivateDirectory()
        defer { removeTree(home) }
        let calls = Recorder<[String]>()
        let commands = AgentCommands(account: { try fakeAccount(home: home.path) }, binary: { bundled },
                                     launchctl: fakeLaunchctl(calls))
        let installed = run(commands, install: true)
        #expect(installed.status == 0 && installed.stderr.isEmpty && installed.stdout.count == 3)
        let removed = run(commands, install: false)
        #expect(removed.status == 0 && removed.stderr.isEmpty)

        let failing = AgentCommands(account: { try fakeAccount(home: home.path) }, binary: { bundled },
                                    launchctl: fakeLaunchctl(calls, status: { _ in 5 }))
        #expect(run(failing, install: true).status == 70)
        let failed = run(failing, install: false)
        #expect(failed.status == 70 && failed.stderr.first?.hasPrefix("blackice agent uninstall: launchctl bootout") == true)
    }
}
