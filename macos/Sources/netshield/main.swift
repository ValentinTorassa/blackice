import Foundation
import NetshieldCLI

let status = CLI.run(
    Array(CommandLine.arguments.dropFirst()),
    stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
)
exit(status)
