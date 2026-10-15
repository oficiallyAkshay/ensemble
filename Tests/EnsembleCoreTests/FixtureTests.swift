import Foundation
import Testing
@testable import EnsembleCore

@Suite struct FixtureTests {
    private func gestureIntents(_ name: String) throws -> [(t: TimeInterval, intent: GestureIntent)] {
        try FixtureReplay.intents(name)
    }

    @Test(arguments: ["none-desk-life", "none-dogfood-1052-fist"])
    func idleHandsNeverSendOrScroll(name: String) throws {
        let intents = try FixtureReplay.intents(name).map(\.intent)
        #expect(!intents.contains(.sendRequested))
        #expect(!intents.contains { if case .scroll = $0 { return true }; return false })
    }

    @Test func idleDeskHandNeverStartsDictation() throws {
        let intents = try FixtureReplay.intents("none-desk-life").map(\.intent)
        #expect(!intents.contains(.talkBegan))
    }

    @Test func thumbsUpHoldSends() throws {
        let intents = try gestureIntents("thumbsUp-hold").map(\.intent)
        // The recording holds each thumbs-up for about a second; with the 1.5 s send hold only the longest sends.
        #expect(intents.filter { $0 == .sendRequested }.count >= 1)
        #expect(!intents.contains(.talkBegan))
    }

    @Test func openPalmHoldDoesNothing() throws {
        let intents = try gestureIntents("openPalm-hold").map(\.intent)
        #expect(intents.isEmpty, "\(intents)")
    }

    @Test func twoFingersHoldNeitherScrollsTalksNorSends() throws {
        let intents = try gestureIntents("twoFingers-hold").map(\.intent)
        #expect(intents.isEmpty, "\(intents)")
    }

    @Test(arguments: [("fist-hold", Pose.fist), ("thumbsUp-hold", Pose.thumbsUp),
                      ("openPalm-hold", Pose.openPalm), ("twoFingers-hold", Pose.twoFingers)])
    func adapterMapsDeliberatePoses(name: String, pose: Pose) throws {
        let obs = try FixtureReplay.observations(name)
        let matching = obs.filter { $0.pose == pose }.count
        #expect(matching > 50, "\(name): \(matching) frames read as \(pose)")
        #expect(obs.contains { $0.present && $0.palmCenter != nil })
    }

    @Test func adapterReportsAbsentHand() {
        let o = HandClassifierAdapter.observation(from: nil, at: 4, classifier: GestureClassifier())
        #expect(!o.present && o.pose == nil && o.palmCenter == nil && o.t == 4)
    }
}
