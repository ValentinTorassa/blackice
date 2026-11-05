import Foundation

/// Control-C, Control-\, SIGTERM and SIGHUP, caught for a while instead of ending blackice, so
/// that a command stopped part way can put things back (`blackice agent connect` leaves
/// accept-all) and the selector can restore the terminal. The handler only records the signal,
/// and system calls it lands in start again (SA_RESTART), so code that waits elsewhere (Touch ID,
/// a reply from the filter) goes on as before. The code that waits for a line, a key or a program
/// looks at `caught` at least every 200 ms instead, whatever thread the signal lands on.
public enum Interrupts {
    static let signals = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]

    /// The last signal caught, or 0. Back to 0 once the outermost `catchAll` is released: outside
    /// it, the signals do what they did before.
    nonisolated(unsafe) static var caught: Int32 = 0
    nonisolated(unsafe) private static var depth = 0

    public static var interrupted: Bool { caught != 0 }

    /// Catches the signals until the function it returns is called, which puts back what was
    /// there before. Programs started meanwhile get the default handling (exec resets a handler,
    /// unlike an ignored signal), so Control-C from the terminal still stops them.
    public static func catchAll() -> () -> Void {
        depth += 1
        var previous: [(Int32, sigaction)] = []
        for number in signals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: { Interrupts.caught = $0 })
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            var old = sigaction()
            if sigaction(number, &action, &old) == 0 { previous.append((number, old)) }
        }
        return {
            for (number, old) in previous.reversed() {
                var old = old
                sigaction(number, &old, nil)
            }
            depth -= 1
            if depth == 0 { caught = 0 }
        }
    }

    /// One line from `descriptor` without its line ending; nil at the end of input, or once a
    /// signal was caught. Read a byte at a time, so nothing is kept back for the next reader.
    static func readLine(from descriptor: Int32 = STDIN_FILENO) -> String? {
        var bytes: [UInt8] = []
        while !interrupted {
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, 200)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
        return nil
    }
}
