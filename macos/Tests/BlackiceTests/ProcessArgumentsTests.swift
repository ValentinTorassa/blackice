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
        let named = ProcessArguments.named(auditToken: token)
        let found = try #require(named.script)
        #expect(named.title == nil)
        // The folder as the kernel has it: /private/var/... for /var/....
        #expect(found.hasSuffix("/blackice-args-\(getpid())/tool.sh") && found.hasPrefix("/"))
        #expect(!found.contains("s3cr3t"))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        #expect(ProcessArguments.named(auditToken: token) == ProcessArguments.Named())
    }

    /// A process that wrote a title over its arguments, as node does for npm: no script is left,
    /// and before 1.0.7 the empty argument after the title read as the process's folder.
    @Test func aRewrittenCommandLineHasATitleAndNoScript() {
        let cases: [([String], String?)] = [
            (["npm run wait", "", "", "", ""], "npm run wait"),
            // perl pads with spaces, and the environment follows.
            (["npm run wait", "      ", "HOME=/Users/me", "TOKEN=secret", ""], "npm run wait"),
            (["next-server (v16.4.1)   ", ""], "next-server (v16.4.1)"),
            (["npm  run   wait", ""], "npm run wait"),
            (["", ""], nil),
            (["evil\u{1B}[2Jname", ""], nil),
            // A title is a command line again: two words, a third after `run` or `exec`, and none
            // from the first option, assignment or URL on, where a token can be.
            (["npm exec vercel --token sk-secret", "", ""], "npm exec vercel"),
            (["npm exec --token sk-secret vercel", ""], "npm exec"),
            (["npm run-script build now", ""], "npm run-script build"),
            (["pnpm run dev extra", ""], "pnpm run dev"),
            (["npm view left-pad version", ""], "npm view"),
            // npm 11.20.0 titles `npm start -- sk-secret` like this: the third word is an argument.
            (["npm start sk-secret", ""], "npm start"),
            (["npm test sk-secret more", ""], "npm test"),
            (["npm config set //registry.npmjs.org/:_authToken=secret", ""], "npm config"),
            (["worker TOKEN=secret", ""], "worker"),
            (["fetch https://me:secret@example.com/x.tgz", ""], "fetch"),
            (["--token sk-secret", ""], nil),
            (["TOKEN=secret", ""], nil),
            // A no-break space or a zero-width one ends a word as a space does.
            (["owner\u{A0}note:\u{A0}approve\u{A0}this\u{A0}host\u{A0}--token\u{A0}sk-secret", ""], "owner note:"),
            (["npm\u{200B}run\u{200B}build\u{200B}--token\u{200B}sk-secret", ""], "npm run build"),
            (["npm\u{3000}exec\u{2003}vercel\u{2009}deploy", ""], "npm exec vercel"),
            // A control character past the words shown does not take the title away.
            (["npm run build --flag\u{1B}[2J", ""], "npm run build"),
            // As it was started: argv[0] is no title.
            (["node", "/opt/homebrew/bin/npm", "run", "wait"], nil),
            (["node"], nil),
        ]
        for (arguments, title) in cases {
            #expect(ProcessArguments.title(arguments) == title, "\(arguments)")
            if arguments.count > 1, arguments[1].allSatisfy({ $0 == " " }) {
                #expect(ProcessArguments.script(arguments) == nil, "\(arguments)")
            }
        }
        // Cut to 64 bytes, on a character.
        #expect(ProcessArguments.title([String(repeating: "a", count: 100), ""]) == String(repeating: "a", count: 64))
        #expect(ProcessArguments.title([String(repeating: "é", count: 40), ""]) == String(repeating: "é", count: 32))
        // A cut right after a word leaves no space at the end.
        #expect(ProcessArguments.title([String(repeating: "a", count: 63) + " b", ""]) == String(repeating: "a", count: 63))
    }

    /// A title as long as the arguments leaves no NUL after it, and argv[1] is then the first
    /// environment string. It is never a script: its value can be a token.
    @Test func anEnvironmentStringIsNeverAScript() {
        let cases: [([String], String?)] = [
            (["my-long-s", "ANTHROPIC_API_KEY=sk-secret"], nil),
            (["my-long-s", "npm_config_user-agent=npm/11"], nil),
            (["python3", "--", "TOKEN=secret"], nil),
            (["python3", "-m", "TOKEN=secret"], nil),
            // A `/` before the `=` is a path.
            (["python3", "/Users/me/a=b.py"], "/Users/me/a=b.py"),
            (["python3", "tools/a=b.py"], "tools/a=b.py"),
        ]
        for (arguments, script) in cases {
            #expect(ProcessArguments.script(arguments) == script, "\(arguments)")
            #expect(ProcessArguments.title(arguments) == nil, "\(arguments)")
        }
    }

    /// A real process that rewrites its command line: Apple's perl, with `$0`.
    @Test func readsARunningProcesssTitle() throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: perl)
        process.arguments = ["-e", "$0 = 'npm run wait'; $| = 1; print qq(ready\\n); <STDIN>", "run", "s3cr3t"]
        process.environment = ["TOKEN": "s3cr3t-in-the-environment"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        // The title is written before "ready".
        #expect(output.fileHandleForReading.availableData == Data("ready\n".utf8))
        let token = try #require(auditToken(of: process.processIdentifier))
        #expect(ProcessArguments.named(auditToken: token) == ProcessArguments.Named(script: nil, title: "npm run wait"))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
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

    @Test func anEventCarriesAValidTitleOnly() throws {
        let identity = AppIdentity.cdhash(String(repeating: "ab", count: 20))
        #expect(HookEvent.App(identity, path: "/opt/node", title: "npm run wait").title == "npm run wait")
        #expect(HookEvent.App(identity, path: "/opt/node", title: "evil\nname").title == nil)
        #expect(HookEvent.App(identity, path: "/opt/node", title: String(repeating: "a", count: 65)).title == nil)
        let event = try HookEvent.connection(app: HookEvent.App(identity, path: "/opt/node", title: "npm run wait"),
                                             host: "registry.npmjs.org", ip: "203.0.113.7", port: 443,
                                             deadline: Date().addingTimeInterval(30))
        let json = try event.input.jsonData()
        #expect(String(decoding: json, as: UTF8.self).contains(#""title":"npm run wait""#))
        #expect(try HookEvent.Input.decode(json).app.title == "npm run wait")
        try event.validate(now: Date())
        // What the daemon refuses from the extension: a title past the limit.
        let long = HookEvent(id: event.id, token: event.token,
                             app: HookEvent.App(signingID: nil, teamID: nil, cdhash: String(repeating: "ab", count: 20),
                                                path: "/opt/node", title: String(repeating: "a", count: 65)),
                             host: "registry.npmjs.org", ip: "203.0.113.7", port: 443, deadline: event.deadline)
        #expect(throws: MessageError.self) { try long.validate(now: Date()) }
        // An event from before the title existed still decodes.
        let old = Data(#"{"app":{"cdhash":"\#(String(repeating: "ab", count: 20))","path":"/opt/node"},"deadline":"2026-11-10T12:00:00Z","event":"connection","host":"example.com","id":"ev-0123abcd","ip":"203.0.113.7","port":443}"#.utf8)
        #expect(try HookEvent.Input.decode(old).app.title == nil)
    }

    @Test func theNewInterpretersCount() {
        for name in ["java", "pypy3.10", "erl", "beam.smp", "elixir", "dotnet", "gawk", "expect"] {
            #expect(Interpreters.contains(path: "/opt/homebrew/bin/" + name), "\(name)")
        }
        #expect(!Interpreters.contains(path: "/opt/homebrew/bin/beam"))
    }
}
