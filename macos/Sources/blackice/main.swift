import Foundation
import BlackiceCLI
import BlackiceSystem

Style.enableForTerminal()
let status = CLI.run(
    Array(CommandLine.arguments.dropFirst()),
    stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    system: NESystemControl(),
    interaction: .terminal(),
    agents: .real()
)
exit(status)
