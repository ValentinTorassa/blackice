import Foundation
import BlackiceCore

/// A list the person picks from: one option, or several.
public struct Choice: Equatable, Sendable {
    public let options: [String]
    public let multiple: Bool
    /// One option: the one highlighted first. Several: the ones ticked first.
    public let initial: [Int]

    public init(options: [String], multiple: Bool, initial: [Int] = []) {
        self.options = options
        self.multiple = multiple
        self.initial = initial
    }
}

/// A key the list reacts to.
enum SelectorKey: Equatable {
    case up, down, space, enter, cancel, digit(Int), other
}

/// Where the person is in a list, and what they ticked; no terminal. With one option to pick, Enter
/// picks the highlighted one. With several, Enter or space ticks or unticks the highlighted option,
/// and a last row, Continue, confirms what is ticked: people press Enter on the app they want, so
/// Enter alone must not end the list.
struct SelectorState: Equatable {
    static let continueLabel = "Continue"

    let choice: Choice
    private(set) var cursor: Int
    private(set) var ticked: Set<Int>

    enum Outcome: Equatable {
        case picked([Int])
        case cancelled
    }

    init(_ choice: Choice) {
        self.choice = choice
        cursor = choice.multiple ? 0 : min(max(choice.initial.first ?? 0, 0), max(choice.options.count - 1, 0))
        ticked = Set(choice.initial.filter { choice.options.indices.contains($0) })
    }

    /// The rows drawn: the options, then Continue when several can be picked.
    var rows: Int { choice.options.count + (choice.multiple ? 1 : 0) }

    /// Whether the highlighted row is Continue.
    var onContinue: Bool { choice.multiple && cursor == choice.options.count }

    /// The outcome when the key ends the list, nil while it goes on.
    mutating func apply(_ key: SelectorKey) -> Outcome? {
        switch key {
        case .up where rows > 0: cursor = (cursor + rows - 1) % rows
        case .down where rows > 0: cursor = (cursor + 1) % rows
        case .cancel: return .cancelled
        case .digit(let number) where number >= 1 && number <= choice.options.count:
            cursor = number - 1
            if choice.multiple { toggle(cursor) }
        case .enter where !choice.multiple:
            return .picked([cursor])
        case .enter, .space:
            guard choice.multiple else { break }
            if onContinue { return .picked(ticked.sorted()) }
            toggle(cursor)
        default: break
        }
        return nil
    }

    private mutating func toggle(_ index: Int) {
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }
}

/// The list drawn in the terminal: ↑ and ↓ (or k and j) move. With one option to pick, Enter picks
/// it; with several, Enter or space ticks an option and Continue confirms. Control-C, Control-D,
/// Escape and q cancel. The terminal is put back as it was in every case.
enum TerminalSelector {
    /// The picked indices, in order; nil when the person cancelled or the terminal cannot do it.
    static func run(_ choice: Choice) -> [Int]? {
        guard !choice.options.isEmpty else { return [] }
        var saved = termios()
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        write("\u{1B}[?25l")
        defer {
            write("\u{1B}[?25h")
            var restore = saved
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
        }

        var state = SelectorState(choice)
        let hint = choice.multiple ? "↑↓ move · Enter picks · Continue when done" : "↑↓ move · Enter picks"
        var drawn = 0
        // An app chose its own name: escape what could redraw the list.
        let options = choice.options.map(Describe.terminalSafe)
        func draw() {
            var text = drawn > 0 ? "\u{1B}[\(drawn)A" : ""
            for (index, option) in options.enumerated() {
                let here = index == state.cursor
                let pointer = here ? Style.command("❯") : " "
                let box = choice.multiple ? (state.ticked.contains(index) ? Style.wrap("◉", "32") + " " : "○ ") : ""
                text += "\r\u{1B}[2K    \(pointer) \(box)\(here ? Style.action(option) : option)\n"
            }
            if choice.multiple {
                let pointer = state.onContinue ? Style.command("❯") : " "
                let label = "→ " + SelectorState.continueLabel
                text += "\r\u{1B}[2K    \(pointer) \(state.onContinue ? Style.action(label) : label)\n"
            }
            text += "\r\u{1B}[2K    \(Style.wrap(hint, "2"))\n"
            write(text)
            drawn = state.rows + 1
        }
        draw()
        while true {
            if let outcome = state.apply(readKey()) {
                // The hint line goes, and Continue with it; the options stay, showing what was picked.
                write(String(repeating: "\u{1B}[1A\r\u{1B}[2K", count: choice.multiple ? 2 : 1))
                switch outcome {
                case .picked(let picks): return picks
                case .cancelled: return nil
                }
            }
            draw()
        }
    }

    private static func readKey() -> SelectorKey {
        guard let byte = readByte() else { return .cancel }
        switch byte {
        case 0x0D, 0x0A: return .enter
        case 0x20: return .space
        case 0x03, 0x04, UInt8(ascii: "q"): return .cancel
        case UInt8(ascii: "k"): return .up
        case UInt8(ascii: "j"): return .down
        case UInt8(ascii: "1")...UInt8(ascii: "9"): return .digit(Int(byte - UInt8(ascii: "0")))
        case 0x1B:
            // An arrow is ESC [ A or ESC O A; ESC alone cancels. The rest of a sequence follows at once.
            guard pending(), let second = readByte() else { return .cancel }
            guard second == UInt8(ascii: "[") || second == UInt8(ascii: "O"), let third = readByte() else { return .other }
            switch third {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            default: return .other
            }
        default: return .other
        }
    }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }

    /// Whether another byte arrives within 50 ms.
    private static func pending() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 50) > 0
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
