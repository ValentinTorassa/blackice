import Darwin
import Foundation
import Testing
@testable import BlackiceCore

/// The audit token of a child process, through its task name port.
private func auditToken(of pid: pid_t) -> Data? {
    var name: mach_port_t = 0
    guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, name) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return withUnsafeBytes(of: &token) { Data($0) }
}

struct ProcessArgumentsTests {
    /// KERN_PROCARGS2: argc, the executable's path, NUL padding, then argv and the environment.
    @Test func readsTheKernelsLayout() {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0, 0]
        for argument in ["python3", "/Users/me/.local/bin/mailctl", "--list"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("TOKEN=secret".utf8) + [0]
        #expect(ProcessArguments.parseArguments(bytes) == ["python3", "/Users/me/.local/bin/mailctl", "--list"])
        // Fewer arguments than argc says, or no argc at all: nothing.
        #expect(ProcessArguments.parseArguments(Array(bytes.prefix(30))) == nil)
        #expect(ProcessArguments.parseArguments([0, 0, 0, 0, 1]) == nil)
    }

    @Test func findsTheScriptPastTheOptions() {
        let cases: [([String], String?)] = [
            (["python3.14", "/Users/me/.local/bin/mailctl", "--token", "x"], "/Users/me/.local/bin/mailctl"),
            (["python3", "-u", "-W", "ignore", "-X", "utf8", "tool.py"], "tool.py"),
            (["python3", "-m", "pip", "install", "x"], "-m pip"),
            (["python3", "-c", "import os"], nil),
            (["python3"], nil),
            (["node", "--require", "/opt/hook.js", "/opt/homebrew/lib/node_modules/vercel/dist/index.js", "deploy"],
             "/opt/homebrew/lib/node_modules/vercel/dist/index.js"),
            (["node", "-e", "fetch('x')"], nil),
            (["bun", "run", "--watch", "server.ts"], "server.ts"),
            (["deno", "run", "-A", "main.ts"], "main.ts"),
            (["/bin/bash", "-o", "pipefail", "deploy.sh"], "deploy.sh"),
            (["/bin/zsh", "-c", "curl x"], nil),
            (["ruby", "-I", "lib", "bin/tool"], "bin/tool"),
            (["perl", "-e", "print"], nil),
            (["python3", "--", "-weird-name.py"], "-weird-name.py"),
        ]
        for (arguments, script) in cases {
            #expect(ProcessArguments.script(arguments) == script, "\(arguments)")
        }
    }

    /// A real interpreter: Apple's sh running a script from a folder, asked by its audit token.
    /// The script comes back absolute, and once the process is gone nothing does.
    @Test func readsARunningInterpretersScript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blackice-args-\(getpid())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("tool.sh")
        try Data("read line\n".utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["tool.sh", "--secret", "s3cr3t"]
        process.currentDirectoryURL = folder
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let token = try #require(auditToken(of: process.processIdentifier))
        let found = try #require(ProcessArguments.script(auditToken: token))
        // The folder as the kernel has it: /private/var/... for /var/....
        #expect(found.hasSuffix("/blackice-args-\(getpid())/tool.sh") && found.hasPrefix("/"))
        #expect(!found.contains("s3cr3t"))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        #expect(ProcessArguments.script(auditToken: token) == nil)
    }

    @Test func anEventCarriesAValidScriptOnly() throws {
        let identity = AppIdentity.cdhash(String(repeating: "ab", count: 20))
        #expect(HookEvent.App(identity, path: "/opt/python3", script: "/Users/me/bin/tool").script == "/Users/me/bin/tool")
        #expect(HookEvent.App(identity, path: "/opt/python3", script: "/Users/me/evil\nname").script == nil)
        let app = HookEvent.App(identity, path: "/opt/python3", script: "/Users/me/bin/tool")
        let event = try HookEvent.connection(app: app, host: "example.com", ip: "203.0.113.7", port: 443,
                                             deadline: Date().addingTimeInterval(30))
        let json = String(decoding: try event.input.jsonData(), as: UTF8.self)
        #expect(json.contains(#""script":"\/Users\/me\/bin\/tool""#) || json.contains(#""script":"/Users/me/bin/tool""#))
        try event.validate(now: Date())
        // Without a script the key is left out, as before.
        let bare = try HookEvent.connection(app: HookEvent.App(identity, path: "/opt/tool"), host: "example.com",
                                            ip: "203.0.113.7", port: 443, deadline: Date().addingTimeInterval(30))
        #expect(!String(decoding: try bare.input.jsonData(), as: UTF8.self).contains("script"))
    }

    @Test func theNewInterpretersCount() {
        for name in ["java", "pypy3.10", "erl", "beam.smp", "elixir", "dotnet", "gawk", "expect"] {
            #expect(Interpreters.contains(path: "/opt/homebrew/bin/" + name), "\(name)")
        }
        #expect(!Interpreters.contains(path: "/opt/homebrew/bin/beam"))
    }
}
