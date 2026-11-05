import Foundation

/// The menu bar app as the CLI reaches it: `blackice menu`, and the offer at the end of the first
/// start. BlackiceMenu's `MenuBar` is the real one; tests and builds without it use `NoMenuBar`.
public protocol MenuBarControlling {
    /// Runs the menu bar app until it quits; returns at once when it runs already.
    func run(output: SystemOutput) -> Int32
    /// Turns Open at Login on and opens the menu bar app now, or turns Open at Login off.
    func setOpenAtLogin(_ on: Bool, output: SystemOutput) -> Int32
    /// Whether the first start asks about the menu bar: the app can open at login and does not yet.
    var canOffer: Bool { get }
    /// After `blackice start`: a menu bar app running another build (one from before an upgrade)
    /// is closed and opened again from this one.
    func reopenIfOutdated(output: SystemOutput)
}

extension MenuBarControlling {
    public func reopenIfOutdated(output: SystemOutput) {}
}

/// No menu bar app.
public struct NoMenuBar: MenuBarControlling {
    public init() {}

    public func run(output: SystemOutput) -> Int32 {
        output.stderr("This blackice has no menu bar app.")
        return ExitCode.unavailable
    }

    public func setOpenAtLogin(_ on: Bool, output: SystemOutput) -> Int32 { run(output: output) }

    public var canOffer: Bool { false }
}

extension CLI {
    /// At the end of the first start: the menu bar app, opened at each login, if the person wants it.
    /// What it prints on failure is its own; the filter is on either way.
    static func offerMenuBar(_ menuBar: MenuBarControlling, interaction: Interaction,
                             stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void) {
        guard menuBar.canOffer, let ask = interaction.ask else { return }
        stdout("")
        while true {
            guard let line = ask("Show blackice in the menu bar and open it at login? [Y/n]: ") else { return }
            let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
            if ["n", "no"].contains(answer) {
                stdout("  Later, with: " + Style.command("blackice menu --login on"))
                return
            }
            if ["", "y", "yes"].contains(answer) {
                _ = menuBar.setOpenAtLogin(true, output: SystemOutput(stdout: stdout, stderr: stderr))
                return
            }
            stdout("  Type y or n.")
        }
    }
}
