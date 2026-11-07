// The interpreters a cdhash rule never counts for (docs/plan.md, "Ad hoc signed code").
//
// A rule for an interpreter's cdhash would let every script it runs reach the rule's hosts: one for
// uv's python3.14 to oauth2.googleapis.com lets any code that python runs, a malicious dependency's
// included, reach that host. That is the supply-chain case blackice exists for, so an interpreter's
// connections are decided one by one, by the agent or the owner; an approval of its cdhash, at
// most 24 hours, still counts.
//
// Told by the file name of the executable, as the kernel has it (FlowFacts.executablePath): ad hoc
// code has nothing else that says what it is, no signing identifier, and a cdhash names one build
// of anything. What the name does not stop: an interpreter copied or renamed to another name. Its
// cdhash is still the interpreter's, though, so a rule matches it only if the owner put that
// cdhash in a rule. blackice.toml names no path, so nothing is refused when it loads. Interpreters
// signed by a developer or by Apple are named by their signing identity, and this list does not
// apply to their rules.

public enum Interpreters {
    /// Lower case. Each also counts with a version after it: python3, python3.14, python3.14t,
    /// ruby3.3, perl5.34, luajit-2.1.0.
    static let names: Set<String> = [
        "python", "pythonw", "pypy", "node", "nodejs", "bun", "deno", "ruby", "perl", "php", "lua", "luajit",
        "tclsh", "wish", "julia", "osascript", "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish", "pwsh",
        "java", "erl", "escript", "elixir", "dotnet", "groovy", "expect", "awk", "gawk", "mawk", "nawk",
    ]
    /// Names that are whole as they are, dots included: Erlang's VM.
    static let exact: Set<String> = ["beam.smp"]
    /// R's, only as they are: with a version, "r" would also take radare2's r2.
    static let unversioned: Set<String> = ["r", "rscript"]

    /// Whether the executable at `path` is an interpreter, by its file name in any case: the
    /// framework build of Python runs as Python.app/Contents/MacOS/Python.
    public static func contains(path: String) -> Bool {
        let file = (path.split(separator: "/").last ?? "").lowercased()
        if exact.contains(file) { return true }
        let name = Array(file.utf8)
        let letters = name.prefix { (97...122).contains($0) }
        let base = String(decoding: letters, as: UTF8.self)
        var version = name.dropFirst(letters.count)
        if version.isEmpty { return names.contains(base) || unversioned.contains(base) }
        guard names.contains(base) else { return false }
        // A version starts with a digit, or with '-', '.' or '_' and a digit.
        if let first = version.first, [45, 46, 95].contains(first) { version = version.dropFirst() }
        guard let digit = version.first, (48...57).contains(digit) else { return false }
        return version.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}
