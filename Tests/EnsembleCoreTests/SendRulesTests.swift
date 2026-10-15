import Testing
@testable import EnsembleCore

@Suite struct SendRulesTests {
    @Test func nothingDictatedRefuses() {
        #expect(SendRules.refusal(spokenAgo: nil, inputAge: 100) == "Nothing dictated in the last 30 seconds")
    }

    @Test func theWindowIsThirtySeconds() {
        #expect(SendRules.refusal(spokenAgo: 30, inputAge: 100) == nil)
        #expect(SendRules.refusal(spokenAgo: 30.5, inputAge: 100) == "Nothing dictated in the last 30 seconds")
    }

    @Test func inputSinceDictationRefuses() {
        #expect(SendRules.refusal(spokenAgo: 10, inputAge: 4) == "Typed or clicked since dictation; not sending")
        #expect(SendRules.refusal(spokenAgo: 10, inputAge: 10) == nil)
        #expect(SendRules.typedRefusal(spokenAgo: 10, inputAge: 9.9) != nil)
        #expect(SendRules.typedRefusal(spokenAgo: 10, inputAge: 10.1) == nil)
        #expect(SendRules.typedRefusal(spokenAgo: 40, inputAge: 5) != nil)     // the window is not this check's business
    }

    /// A fresh dictation and no input since, but the user swiped to a full-screen call: nothing is sent.
    @Test func anotherAppInFrontRefuses() {
        #expect(SendRules.refusal(spokenAgo: 5, inputAge: 100) == nil)
        #expect(SendRules.frontRefusal(claudeInFront: false) == "Claude is not the app in front")
        #expect(SendRules.frontRefusal(claudeInFront: true) == nil)
    }

    /// A click that left the draft unchanged while the press waited in the bridge queue: the last check refuses.
    @Test func inputWhileThePressWaitedRefuses() {
        #expect(SendRules.pressRefusal(claudeInFront: true, spokenAgo: 3, inputAge: 0.2) == "Typed or clicked since dictation; not sending")
        #expect(SendRules.pressRefusal(claudeInFront: false, spokenAgo: 3, inputAge: 100) == "Claude is not the app in front")
        #expect(SendRules.pressRefusal(claudeInFront: true, spokenAgo: 3, inputAge: 3.1) == nil)
    }
}
