import Foundation
import NetshieldCLI
import NetshieldSystem

let status = CLI.run(
    Array(CommandLine.arguments.dropFirst()),
    stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    system: NESystemControl()
)
exit(status)
