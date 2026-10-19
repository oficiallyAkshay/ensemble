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

    /// A click that leaves the draft unchanged, made while the press waited in the queue: the last check refuses it.
    @Test func pressRefusesInputSinceDictation() {
        #expect(SendRules.pressRefusal(claudeInFront: true, spokenAgo: 10, inputAge: 2) == "Typed or clicked since dictation; not sending")
        #expect(SendRules.pressRefusal(claudeInFront: true, spokenAgo: 10, inputAge: 10.5) == nil)
        #expect(SendRules.pressRefusal(claudeInFront: false, spokenAgo: 10, inputAge: 100) == "Claude is not the app in front")
        // Not in front wins over typed, so the reason stays the one the earlier check gave.
        #expect(SendRules.pressRefusal(claudeInFront: false, spokenAgo: 10, inputAge: 2) == "Claude is not the app in front")
    }
}
