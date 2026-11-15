import Foundation

/// Control-C, Control-\, SIGTERM and SIGHUP, caught for a while instead of ending blackice, so
/// that a command stopped part way can put things back (`blackice agent connect` leaves
/// accept-all, an upgrade's `blackice start` turns the filter back on) and the selector can
/// restore the terminal. SIGPIPE too: a command run over ssh with no terminal gets it at its next
/// line once the session drops, and it would end blackice as SIGHUP does; caught, the write fails
/// and the command goes on to put things back. The handler only records the signal,
/// and system calls it lands in start again (SA_RESTART), so code that waits elsewhere (Touch ID,
/// a reply from the filter) goes on as before. The code that waits for a line, a key or a program
/// looks at `caught` at least every 200 ms instead, whatever thread the signal lands on.
public enum Interrupts {
    static let signals = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE]

    /// The last signal caught, or 0. Back to 0 once the outermost `catchAll` is released: outside
    /// it, the signals do what they did before.
    nonisolated(unsafe) static var caught: Int32 = 0
    /// How many signals were caught, back to 0 with `caught`. After the first only Control-C and
    /// Control-\ count: closing a terminal or dropping an ssh session usually brings SIGHUP twice,
    /// from the shell and then from the kernel to the foreground process group, and once the
    /// session is gone each line written brings a broken pipe. None of them is a person pressing
    /// Control-C again. An upgrade's `blackice start` goes on waiting at the first signal and
    /// stops at the second (UpgradeInterruption).
    nonisolated(unsafe) public private(set) static var count = 0
    /// Whether SIGTERM was among the signals caught, back to false with `caught`. It comes from
    /// launchd, a supervisor or kill(1) rather than a person, often with SIGKILL a few seconds
    /// later, so an upgrade's start does not wait on at it as at a first Control-C
    /// (UpgradeInterruption).
    nonisolated(unsafe) public private(set) static var terminated = false
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
            action.__sigaction_u = __sigaction_u(__sa_handler: { signal in
                if Interrupts.caught == 0 || signal == SIGINT || signal == SIGQUIT { Interrupts.count += 1 }
                if signal == SIGTERM { Interrupts.terminated = true }
                Interrupts.caught = signal
            })
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
            if depth == 0 {
                caught = 0
                count = 0
                terminated = false
            }
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

/// How an upgrade's `blackice start` takes Control-C and the other stop signals (`Interrupts`)
/// while it waits with blackice's filter turned off: for the kernel to let go of the filter it
/// turned off, or for macOS to finish putting the new build of the extension in place. Turned
/// back on at the first signal, the filter would start while the kernel is still disconnecting
/// the one turned off, be held with it, and let no new connection through until the kernel is
/// done (4 to 59 s in six upgrades on 10 and 11 November 2026, 116 s once; FilterDisconnect): the
/// stall the wait is there to avoid. Turned on during the request, it would be replaced while on,
/// which is how that stall comes about. So the first signal is told what start waits for, and the
/// wait goes on to its end, as long as it would have lasted; a second ends it at once. SIGTERM
/// ends it at once too, first or not: launchd, a supervisor or kill(1) sends it, often with
/// SIGKILL a few seconds later, and start killed while it waits leaves the filter saved off.
/// Either way start then turns the filter back on and exits with 130.
public struct UpgradeInterruption: Sendable {
    /// What start waits for.
    public enum Wait: Equatable, Sendable {
        /// The kernel, to let go of the filter that was turned off (KernelFilters.gone).
        case kernel
        /// macOS, to finish the request that puts the new build of the extension in place.
        case request
    }

    /// What start does about the signals caught so far.
    public enum Action: Equatable, Sendable {
        /// Goes on waiting: no signal yet, or the first, already told about.
        case wait
        /// Goes on waiting, having said this line: the first signal.
        case tell(String)
        /// Stops waiting, and turns the filter back on now: a second signal, or SIGTERM.
        case stop
    }

    /// Whether the line was said: once per start, whichever wait the first signal came in.
    private var told = false

    public init() {}

    /// What to do while waiting for `wait`, `interrupts` signals having been caught
    /// (`Interrupts.count`), SIGTERM among them when `terminated` (`Interrupts.terminated`).
    public mutating func action(_ wait: Wait, interrupts: Int, terminated: Bool = false) -> Action {
        if terminated { return .stop }
        switch interrupts {
        case ...0:
            return .wait
        case 1:
            guard !told else { return .wait }
            told = true
            return .tell(CLI.waitingAfterInterruptLine(wait))
        default:
            return .stop
        }
    }

    /// `action`, with its line said through `say`: whether to stop waiting now. Asked before each
    /// look at what start waits for.
    public mutating func stopWaiting(_ wait: Wait, interrupts: Int, terminated: Bool = false,
                                     say: (String) -> Void) -> Bool {
        switch action(wait, interrupts: interrupts, terminated: terminated) {
        case .wait:
            return false
        case .tell(let line):
            say(line)
            return false
        case .stop:
            return true
        }
    }
}
