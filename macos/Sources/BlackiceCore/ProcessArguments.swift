import Darwin
import Foundation

// The script an interpreter runs, for its events (docs/plan.md, "Developer tools in an interpreter").
//
// For python, node and the other interpreters (Interpreters), the program that connects is the
// interpreter: uv's python3.14 for every uv tool, Homebrew's node for every npm CLI, so the event
// alone cannot tell mailctl from any other script. The script its command line names can, for the
// agent and the owner's notes. Any program can start an interpreter with any script name, so the
// script is shown and never trusted: no rule names it, and an answer for it only narrows what the
// answer covers (ScriptScope). Only the script is taken, never the other arguments, which can hold
// tokens. A process that wrote a title over its arguments has no script left to read: its title is
// shown in the script's place, and trusted as little.
public enum ProcessArguments {
    /// What an interpreter's command line names.
    public struct Named: Equatable, Sendable {
        /// The script: its path (absolute when the process's folder is known), or `-m module` for
        /// `python -m`. nil when the command line names none (`python3 -c ...`, a bare REPL).
        public var script: String?
        /// The title the process wrote over its arguments (`title`); the script is then nil.
        public var title: String?

        public init(script: String? = nil, title: String? = nil) {
            self.script = script
            self.title = title
        }
    }

    /// What the command line of the interpreter that `auditToken` names says. Neither when it
    /// cannot be read or the process is gone. The token is checked again after the read: a PID
    /// used again by another process has a new pidversion.
    public static func named(auditToken: Data) -> Named {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return Named() }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        let pid = pid_t(bitPattern: token.val.5)
        guard let arguments = arguments(pid: pid) else { return Named() }
        var named = Named(title: title(arguments))
        if let found = script(arguments) {
            let folder = found.hasPrefix("/") || found.hasPrefix("-m ") ? nil : currentFolder(pid: pid)
            let text = folder.map { ($0 as NSString).appendingPathComponent(found) } ?? found
            named.script = validPath(text) ? text : nil
        }
        // Still the same process: proc_pidpath_audittoken fails once the pidversion changed.
        guard CodeIdentity.kernelPath(auditToken: auditToken) != nil else { return Named() }
        return named
    }

    /// The command line of `pid`, from KERN_PROCARGS2: argc, the executable's path, padding, then
    /// argv. nil when it cannot be read.
    static func arguments(pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2's bytes to argv.
    static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let count = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard count > 0, count < 4096 else { return nil }
        var index = 4
        // The executable's path, then the NULs that pad it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == count ? arguments : nil
    }

    /// Whether the process wrote a title over its arguments. node does it for npm (`process.title`,
    /// through libuv), perl for `$0 = ...`, setproctitle for others: the title goes where argv[0]
    /// began and the bytes left of the old arguments are set to NUL, or to spaces by perl, so the
    /// argument after it reads as empty or as spaces. What the process was started with is gone.
    static func rewritten(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && blank(arguments[1])
    }

    private static func blank(_ argument: String) -> Bool { argument.utf8.allSatisfy { $0 == 0x20 } }

    /// The title of a process that wrote one over its arguments, cut to `maximumTitleBytes`. nil
    /// for a command line as it was started, and for a title with a control character. A process
    /// picks its title as it picks its arguments, so it is shown and never trusted.
    static func title(_ arguments: [String]) -> String? {
        guard rewritten(arguments) else { return nil }
        var title = ""
        var bytes = 0
        for character in arguments[0] {
            bytes += character.utf8.count
            guard bytes <= HookEvent.maximumTitleBytes else { break }
            title.append(character)
        }
        while title.last == " " { title.removeLast() }
        return validTitle(title) ? title : nil
    }

    /// The script in an interpreter's argv: the first argument that is not an option, after the
    /// options that take a value. nil for code given inline (`-c`, `-e`), for none at all, and
    /// for a command line the process wrote over (`rewritten`).
    static func script(_ arguments: [String]) -> String? {
        guard let program = arguments.first, !rewritten(arguments) else { return nil }
        let name = (program.split(separator: "/").last.map(String.init) ?? program).lowercased()
        let family = Family(name)
        var index = 1
        var skippedCommand = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { return index < arguments.count ? named(arguments[index]) : nil }
            if argument.hasPrefix("-") || (family == .shell && argument.hasPrefix("+")) {
                if family.inline.contains(argument) { return nil }
                if family == .python, argument == "-m" {
                    return index < arguments.count ? named(arguments[index]).map { "-m " + $0 } : nil
                }
                if family.takesValue.contains(argument) { index += 1 }
                continue
            }
            // `bun run x.ts`, `deno run x.ts`: the command comes before the script.
            if family == .runner, !skippedCommand, family.commands.contains(argument) {
                skippedCommand = true
                continue
            }
            return named(argument)
        }
        return nil
    }

    /// An argument as a script's name. nil for an empty one, and for one that reads as an
    /// environment string, `NAME=value` with no `/` before the `=`. KERN_PROCARGS2 gives the
    /// arguments and then the environment with nothing between them, and a title as long as the
    /// arguments leaves no NUL to count them by: the argument after it is then the process's
    /// first environment string, which can hold a token and must not reach an event.
    static func named(_ argument: String) -> String? {
        guard !blank(argument) else { return nil }
        if let equals = argument.firstIndex(of: "="), !argument[..<equals].contains("/") { return nil }
        return argument
    }

    /// The options that matter, by interpreter.
    enum Family: Equatable {
        case python, node, runner, ruby, perl, shell, osascript, other

        init(_ name: String) {
            let letters = String(name.prefix { $0.isLetter })
            switch letters {
            case "python", "pythonw", "pypy": self = .python
            case "node", "nodejs": self = .node
            case "bun", "deno": self = .runner
            case "ruby": self = .ruby
            case "perl": self = .perl
            case "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish": self = .shell
            case "osascript": self = .osascript
            default: self = .other
            }
        }

        /// Options whose code follows on the command line: there is no script to name.
        var inline: Set<String> {
            switch self {
            case .python: ["-c"]
            case .node, .runner: ["-e", "--eval", "-p", "--print"]
            case .ruby: ["-e"]
            case .perl: ["-e", "-E"]
            case .shell: ["-c"]
            case .osascript: ["-e"]
            case .other: ["-c", "-e"]
            }
        }

        /// Options that take the next argument as their value.
        var takesValue: Set<String> {
            switch self {
            case .python: ["-W", "-X", "--check-hash-based-pycs"]
            case .node, .runner: ["-r", "--require", "--import", "--loader", "--experimental-loader", "-C",
                                  "--conditions", "--input-type", "--title", "--env-file", "--config", "-c"]
            case .ruby: ["-I", "-r", "-C", "-E"]
            case .perl: ["-I", "-M", "-m"]
            case .shell: ["-o", "+o", "-O", "+O", "--rcfile", "--init-file"]
            case .osascript: ["-l", "-s"]
            case .other: []
            }
        }

        /// `bun` and `deno` commands that run a script.
        var commands: Set<String> { ["run", "x", "test"] }
    }

    /// The process's current folder, to make a relative script absolute.
    static func currentFolder(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }
}
