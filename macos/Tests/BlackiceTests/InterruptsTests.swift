import Foundation
import Testing
@testable import BlackiceCLI

/// Signal handling is the whole process's: these run one at a time.
@Suite(.serialized) struct InterruptsTests {
    private func handling(_ signal: Int32) -> [UInt8] {
        var current = sigaction()
        sigaction(signal, nil, &current)
        return withUnsafeBytes(of: current.__sigaction_u) { Array($0) }
    }

    /// Runs `body` with the signals unblocked on this thread. Tests run on threads that block
    /// them, unlike blackice's main thread; call it only while they are caught.
    private func unblocked<T>(_ body: () -> T) -> T {
        var signals = sigset_t()
        sigemptyset(&signals)
        Interrupts.signals.forEach { sigaddset(&signals, $0) }
        var previous = sigset_t()
        pthread_sigmask(SIG_UNBLOCK, &signals, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return body()
    }

    @Test func aSignalIsRecordedWhileCaughtAndTheHandlingBeforeComesBack() {
        let before = Interrupts.signals.map(handling)
        let release = Interrupts.catchAll()
        #expect(!Interrupts.interrupted)
        // To the process, as kill(1) sends it: raise() is refused on the threads tests run on.
        let deadline = Date().addingTimeInterval(5)
        unblocked {
            kill(getpid(), SIGTERM)
            while !Interrupts.interrupted, Date() < deadline { usleep(10_000) }
        }
        #expect(Interrupts.caught == SIGTERM && Interrupts.count == 1 && Interrupts.terminated)
        // A catch inside another sees what the outer one caught at once, as an upgrade's start
        // run by agent connect does before it turns the filter off, and keeps it.
        let inner = Interrupts.catchAll()
        #expect(Interrupts.interrupted && Interrupts.count == 1)
        inner()
        #expect(Interrupts.interrupted && Interrupts.terminated)
        release()
        #expect(!Interrupts.interrupted && !Interrupts.terminated)
        #expect(Interrupts.signals.map(handling) == before)
    }

    /// A write to a pipe nobody reads any more, as a command run over ssh with no terminal makes
    /// once the session drops: caught as the other signals are, and the write fails.
    @Test func aBrokenPipeIsCaught() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        defer { close(ends[1]) }
        let release = Interrupts.catchAll()
        defer { release() }
        let byte: [UInt8] = [0x0A]
        // macOS sends it to the process, so any thread that does not block it may take it.
        let deadline = Date().addingTimeInterval(5)
        #expect(unblocked { () -> Int in
            let written = write(ends[1], byte, 1)
            while !Interrupts.interrupted, Date() < deadline { usleep(10_000) }
            return written
        } == -1)
        #expect(Interrupts.caught == SIGPIPE)
    }

    /// The first signal counts, and after it Control-C and Control-\ do, so that an upgrade's start
    /// can tell a second Control-C from the first. A closed terminal or a dropped ssh session
    /// usually brings SIGHUP twice, from the shell and from the kernel, and then a broken pipe for
    /// each line written: none of those counts again. Back to 0 with the outermost release.
    @Test func afterTheFirstSignalOnlyControlCAndControlBackslashCount() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        defer { close(ends[1]) }
        let release = Interrupts.catchAll()
        #expect(Interrupts.count == 0)
        let process = getpid()
        func send(_ signal: Int32, until count: Int) {
            let deadline = Date().addingTimeInterval(5)
            unblocked {
                kill(process, signal)
                while Interrupts.caught != signal || Interrupts.count < count, Date() < deadline { usleep(10_000) }
            }
        }
        send(SIGHUP, until: 1)
        #expect(Interrupts.count == 1)
        let byte: [UInt8] = [0x0A]
        let deadline = Date().addingTimeInterval(5)
        #expect(unblocked { () -> Int in
            let written = write(ends[1], byte, 1)
            while Interrupts.caught != SIGPIPE, Date() < deadline { usleep(10_000) }
            return written
        } == -1)
        #expect(Interrupts.caught == SIGPIPE && Interrupts.count == 1)
        send(SIGHUP, until: 1)
        #expect(Interrupts.caught == SIGHUP && Interrupts.count == 1 && !Interrupts.terminated)
        // SIGTERM does not count again, but is kept apart: an upgrade's start stops at it.
        send(SIGTERM, until: 1)
        #expect(Interrupts.caught == SIGTERM && Interrupts.count == 1 && Interrupts.terminated)
        send(SIGQUIT, until: 2)
        #expect(Interrupts.count == 2)
        send(SIGHUP, until: 2)
        #expect(Interrupts.caught == SIGHUP && Interrupts.count == 2)
        send(SIGINT, until: 3)
        #expect(Interrupts.count == 3)
        // A catch inside another keeps the count.
        let inner = Interrupts.catchAll()
        inner()
        #expect(Interrupts.count == 3)
        release()
        #expect(Interrupts.count == 0 && !Interrupts.interrupted && !Interrupts.terminated)
    }

    @Test func aLineIsReadUpToItsEnd() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { close(ends[0]) }
        let text = Array("yes\r\nnext\nlast".utf8)
        #expect(write(ends[1], text, text.count) == text.count)
        close(ends[1])
        #expect(Interrupts.readLine(from: ends[0]) == "yes")
        #expect(Interrupts.readLine(from: ends[0]) == "next")
        #expect(Interrupts.readLine(from: ends[0]) == "last")
        #expect(Interrupts.readLine(from: ends[0]) == nil)
    }

    /// A question waiting for a line gives up once a signal is caught.
    @Test func aCaughtSignalEndsTheWaitForALine() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { close(ends[0]); close(ends[1]) }
        let release = Interrupts.catchAll()
        defer { release() }
        let process = getpid()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { kill(process, SIGINT) }
        let started = Date()
        #expect(unblocked { Interrupts.readLine(from: ends[0]) } == nil)
        #expect(Interrupts.caught == SIGINT && Date().timeIntervalSince(started) < 5)
    }

    /// The program gets Control-C as from the terminal (the default handling, not an ignored
    /// signal), and a SIGTERM sent to blackice is passed on to it.
    @Test func aProgramRunAttachedReportsHowItEnded() {
        #expect(AgentMachine.runAttached("/bin/sh", ["-c", "exit 3"], [:]) == 3)
        #expect(AgentMachine.runAttached("/bin/sh", ["-c", "kill -INT $$"], [:]) == 128 + SIGINT)
        let started = Date()
        #expect(unblocked { AgentMachine.runAttached("/bin/sh", ["-c", "kill -TERM $PPID; exec /bin/sleep 5"], [:]) }
            == 128 + SIGTERM)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(AgentMachine.runAttached("/nonexistent/program", [], [:]) == 127)
        #expect(!Interrupts.interrupted)
    }
}
