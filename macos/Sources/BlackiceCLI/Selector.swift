import Foundation

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

/// The list drawn in the terminal: ↑ and ↓ (or k and j) move, space ticks an option when several
/// can be picked, Enter confirms. Control-C, Control-D, Escape and q cancel. The terminal is put
/// back as it was in every case.
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

        var cursor = choice.multiple ? 0 : min(max(choice.initial.first ?? 0, 0), choice.options.count - 1)
        var ticked = Set(choice.initial.filter { choice.options.indices.contains($0) })
        let hint = choice.multiple ? "↑↓ move · space picks · Enter confirms" : "↑↓ move · Enter picks"
        var drawn = 0
        func draw() {
            var text = drawn > 0 ? "\u{1B}[\(drawn)A" : ""
            for (index, option) in choice.options.enumerated() {
                let pointer = index == cursor ? Style.command("❯") : " "
                let box = choice.multiple ? (ticked.contains(index) ? Style.wrap("◉", "32") + " " : "○ ") : ""
                let label = index == cursor ? Style.action(option) : option
                text += "\r\u{1B}[2K    \(pointer) \(box)\(label)\n"
            }
            text += "\r\u{1B}[2K    \(Style.wrap(hint, "2"))\n"
            write(text)
            drawn = choice.options.count + 1
        }
        draw()
        while true {
            switch readKey() {
            case .up: cursor = (cursor + choice.options.count - 1) % choice.options.count
            case .down: cursor = (cursor + 1) % choice.options.count
            case .space where choice.multiple:
                if ticked.contains(cursor) { ticked.remove(cursor) } else { ticked.insert(cursor) }
            case .digit(let number) where (1...choice.options.count).contains(number):
                cursor = number - 1
                if choice.multiple { if ticked.contains(cursor) { ticked.remove(cursor) } else { ticked.insert(cursor) } }
            case .enter:
                // The hint line goes; the list stays, showing what was picked.
                write("\u{1B}[1A\r\u{1B}[2K")
                return choice.multiple ? ticked.sorted() : [cursor]
            case .cancel:
                write("\u{1B}[1A\r\u{1B}[2K")
                return nil
            default: break
            }
            draw()
        }
    }

    private enum Key { case up, down, space, enter, cancel, digit(Int), other }

    private static func readKey() -> Key {
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
