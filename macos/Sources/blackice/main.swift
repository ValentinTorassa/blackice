import Foundation
import BlackiceCLI
import BlackiceMenu
import BlackiceSystem

let arguments = Array(CommandLine.arguments.dropFirst())
// Blackice.app opened from Finder, Spotlight or as a login item runs as the menu bar app;
// MenuLaunch.opensAsApp says how that is told apart from a command.
if MenuLaunch.opensAsApp(arguments: arguments) { exit(MenuBar.runAsApp()) }
Style.enableForTerminal()
let status = CLI.run(
    arguments,
    // A terminal that hung up refuses writes; what a command does next (putting things back) goes on.
    stdout: { try? FileHandle.standardOutput.write(contentsOf: Data(($0 + "\n").utf8)) },
    stderr: { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) },
    system: NESystemControl(),
    interaction: .terminal(),
    agents: .real(),
    menuBar: MenuBar()
)
exit(status)
