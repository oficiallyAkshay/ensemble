import Testing
@testable import EnsembleCore

@Suite("Light mode scrolling")
struct LightScrollTests {
    /// A browser (pid 500) in front with the look point on its window: the one case that scrolls.
    private func owner(enabled: Bool = true, claudeFront: Bool = false, onClaudeSession: Bool = false, dictating: Bool = false,
                       handsBusy: Bool = false, front: Int32? = 500, atLook: Int32? = 500) -> Int32? {
        LightScroll.owner(enabled: enabled, claudeFront: claudeFront, onClaudeSession: onClaudeSession, dictating: dictating,
                          handsBusy: handsBusy, frontPID: front, ownerAtLook: atLook)
    }

    @Test func scrollsTheFrontAppWhenOn() {
        #expect(owner() == 500)
    }

    @Test func doesNothingWhenOff() {
        #expect(owner(enabled: false) == nil)
    }

    @Test func claudeInFrontKeepsTheClaudePath() {
        #expect(owner(claudeFront: true) == nil)
        #expect(owner(onClaudeSession: true) == nil)
        #expect(owner(dictating: true) == nil)
    }

    @Test func holdsStillWhileTypingOrUsingTheMouse() {
        #expect(owner(handsBusy: true) == nil)
    }

    @Test func refusesAWindowThatIsNotTheFrontApps() {
        #expect(owner(atLook: 600) == nil)
        #expect(owner(atLook: nil) == nil)
        #expect(owner(front: nil) == nil)
    }

    @Test func onlyPinchAndDragPasses() {
        #expect(LightScroll.allows(.dragScroll(handDy: 3)))
        #expect(LightScroll.allows(.dragScrollEnded))
        #expect(!LightScroll.allows(.scroll(dy: 3)))
        #expect(!LightScroll.allows(.talkBegan))
        #expect(!LightScroll.allows(.talkEnded(.released)))
        #expect(!LightScroll.allows(.sendRequested))
        #expect(!LightScroll.allows(.maximizeSession))
        #expect(!LightScroll.allows(.evenOutSessions))
    }
}
