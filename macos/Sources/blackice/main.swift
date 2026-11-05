import Foundation
import BlackiceCLI
import BlackiceSystem

Style.enableForTerminal()
let status = CLI.run(
    Array(CommandLine.arguments.dropFirst()),
    // A terminal that hung up refuses writes; what a command does next (putting things back) goes on.
    stdout: { try? FileHandle.standardOutput.write(contentsOf: Data(($0 + "\n").utf8)) },
    stderr: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) },
    system: NESystemControl(),
    interaction: .terminal(),
    agents: .real()
)
exit(status)
