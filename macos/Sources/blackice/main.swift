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
    stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    system: NESystemControl(),
    interaction: .terminal(),
    agents: .real(),
    menuBar: MenuBar()
)
exit(status)
