import Testing
@testable import BlackiceCLI

struct SelectorTests {
    private func run(_ choice: Choice, _ keys: [SelectorKey]) -> SelectorState.Outcome? {
        var state = SelectorState(choice)
        for key in keys {
            if let outcome = state.apply(key) { return outcome }
        }
        return nil
    }

    @Test func oneOptionIsPickedWithEnter() {
        let modes = Choice(options: ["accept-all", "ask", "block-all"], multiple: false)
        #expect(run(modes, [.enter]) == .picked([0]))
        #expect(run(modes, [.down, .enter]) == .picked([1]))
        #expect(run(modes, [.up, .enter]) == .picked([2]))
        #expect(run(Choice(options: ["a", "b"], multiple: false, initial: [1]), [.enter]) == .picked([1]))
        // Space does nothing in a list of one pick.
        #expect(run(modes, [.space]) == nil)
    }

    /// The 3 November recording: the person moved to an app and pressed Enter, and the list closed
    /// with nothing picked. Enter now ticks it, and Continue confirms.
    @Test func enterTicksAppsAndContinueConfirms() {
        let apps = Choice(options: ["Caffeine", "Clipy", "Slack", "Another app: type its path or name"], multiple: true)
        #expect(run(apps, [.down, .enter]) == nil)
        #expect(run(apps, [.down, .enter, .down, .enter, .down, .down, .enter]) == .picked([1, 2]))
        // Space ticks too, and Enter on a ticked app unticks it.
        #expect(run(apps, [.space, .down, .enter, .enter, .down, .down, .down, .enter]) == .picked([0]))
        // Digits tick the app with that number.
        #expect(run(apps, [.digit(3), .digit(1), .up, .up, .enter]) == nil)
        #expect(run(apps, [.digit(3), .digit(1), .up, .enter]) == .picked([0, 2]))
    }

    @Test func continueRightAwayPicksNothing() {
        let apps = Choice(options: ["Slack", "Another app: type its path or name"], multiple: true)
        // Up from the first app wraps to Continue.
        var state = SelectorState(apps)
        #expect(state.apply(.up) == nil)
        #expect(state.onContinue)
        #expect(state.apply(.enter) == .picked([]))
        #expect(SelectorState(apps).rows == 3)
    }

    @Test func cancellingEndsEitherList() {
        #expect(run(Choice(options: ["a"], multiple: false), [.cancel]) == .cancelled)
        #expect(run(Choice(options: ["a"], multiple: true), [.enter, .cancel]) == .cancelled)
    }

    @Test func ticksStartFromTheInitialOnes() {
        let apps = Choice(options: ["a", "b", "c"], multiple: true, initial: [2, 7])
        #expect(run(apps, [.up, .enter]) == .picked([2]))
    }
}
