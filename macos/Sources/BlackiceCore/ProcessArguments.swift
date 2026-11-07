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
// tokens.
public enum ProcessArguments {
    /// The script the interpreter that `auditToken` names runs: its path (absolute when the
    /// process's folder is known), or `-m module` for `python -m`. nil when the command line names
    /// none (`python3 -c ...`, a bare REPL), cannot be read, or the process is gone. The token is
    /// checked again after the read: a PID used again by another process has a new pidversion.
    public static func script(auditToken: Data) -> String? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        let pid = pid_t(bitPattern: token.val.5)
        guard let arguments = arguments(pid: pid), let found = script(arguments) else { return nil }
        let folder = found.hasPrefix("/") || found.hasPrefix("-m ") ? nil : currentFolder(pid: pid)
        // Still the same process: proc_pidpath_audittoken fails once the pidversion changed.
        guard CodeIdentity.kernelPath(auditToken: auditToken) != nil else { return nil }
        let text = folder.map { ($0 as NSString).appendingPathComponent(found) } ?? found
        return validPath(text) ? text : nil
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

    /// The script in an interpreter's argv: the first argument that is not an option, after the
    /// options that take a value. nil for code given inline (`-c`, `-e`) and for none at all.
    static func script(_ arguments: [String]) -> String? {
        guard let program = arguments.first else { return nil }
        let name = (program.split(separator: "/").last.map(String.init) ?? program).lowercased()
        let family = Family(name)
        var index = 1
        var skippedCommand = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { return index < arguments.count ? arguments[index] : nil }
            if argument.hasPrefix("-") || (family == .shell && argument.hasPrefix("+")) {
                if family.inline.contains(argument) { return nil }
                if family == .python, argument == "-m" {
                    return index < arguments.count ? "-m " + arguments[index] : nil
                }
                if family.takesValue.contains(argument) { index += 1 }
                continue
            }
            // `bun run x.ts`, `deno run x.ts`: the command comes before the script.
            if family == .runner, !skippedCommand, family.commands.contains(argument) {
                skippedCommand = true
                continue
            }
            return argument
        }
        return nil
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
