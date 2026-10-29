import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct HandSkeletonTests {
    private func frame(_ build: (Int) -> CGPoint?) -> HandSkeletonFrame {
        HandSkeletonFrame(points: (0..<HandSkeleton.joints.count).map(build))
    }

    @Test func aHandHasTwentyOneDistinctJointsAndEveryBoneUsesTwoOfThem() {
        #expect(HandSkeleton.joints.count == 21)
        #expect(Set(HandSkeleton.joints).count == 21)
        #expect(HandSkeleton.bones.count == 21)
        for bone in HandSkeleton.bones {
            #expect(bone.from != bone.to)
            #expect((0..<21).contains(bone.from) && (0..<21).contains(bone.to))
        }
        // Each of the five fingertips ends exactly one bone chain.
        let tips = [4, 8, 12, 16, 20]
        for tip in tips { #expect(HandSkeleton.bones.filter { $0.to == tip }.count == 1) }
    }

    @Test func selfieFlipsLeftToRightAndPutsTheOriginAtTheTopLeft() {
        // Vision's origin is bottom-left; the inset's is top-left and mirrored like a front camera preview.
        #expect(HandSkeleton.selfie(CGPoint(x: 0, y: 0)) == CGPoint(x: 1, y: 1))
        #expect(HandSkeleton.selfie(CGPoint(x: 0.25, y: 0.9)).x == 0.75)
        let up = HandSkeleton.selfie(CGPoint(x: 0.5, y: 0.9))
        #expect(abs(up.y - 0.1) < 1e-12)
    }

    @Test func segmentsSkipBonesWithAMissingJoint() {
        let full = frame { CGPoint(x: Double($0) / 21, y: 0.5) }
        #expect(HandSkeleton.segments(of: full.points).count == 21)
        // Dropping the index tip removes only the one bone that ends there.
        let noIndexTip = frame { $0 == 8 ? nil : CGPoint(x: Double($0) / 21, y: 0.5) }
        #expect(HandSkeleton.segments(of: noIndexTip.points).count == 20)
        #expect(HandSkeleton.segments(of: []).isEmpty)
    }

    @Test func smootherMovesPartwayBetweenReadingsAndReachesTheTarget() {
        var s = HandSkeletonSmoother(timeConstant: 0.05, holdAfterLoss: 5)
        s.observe(frame { _ in CGPoint(x: 0, y: 0) }, at: 0)
        let start = s.sample(at: 0)
        #expect(start[0] == CGPoint(x: 1, y: 1))               // first sample snaps to the mirrored reading

        s.observe(frame { _ in CGPoint(x: 1, y: 1) }, at: 0.01)    // selfie(1,1) = (0,0)
        let mid = s.sample(at: 0.05)                           // one time constant after the last sample
        let x = mid[0]!.x
        #expect(x < 1 && x > 0)
        #expect(abs(x - exp(-1.0)) < 0.01)                     // 63% of the way from 1 to 0

        var last = mid
        for step in 1...40 { last = s.sample(at: 0.05 + Double(step) * 0.033) }
        #expect(abs(last[0]!.x) < 0.001)
    }

    @Test func aJointThatBlinksOutKeepsItsPlaceBrieflyThenGoes() {
        var s = HandSkeletonSmoother(timeConstant: 0.05, holdAfterLoss: 0.25)
        s.observe(frame { _ in CGPoint(x: 0.5, y: 0.5) }, at: 0)
        #expect(s.sample(at: 0)[8] != nil)
        s.observe(nil, at: 0.1)
        #expect(s.sample(at: 0.2)[8] != nil)
        #expect(s.sample(at: 0.3)[8] == nil)
        // It comes back where it is read again, without easing from the old place.
        s.observe(frame { _ in CGPoint(x: 0.2, y: 0.2) }, at: 0.4)
        #expect(s.sample(at: 0.4)[8] == HandSkeleton.selfie(CGPoint(x: 0.2, y: 0.2)))
    }

    @Test func aLongPauseSnapsInsteadOfSweeping() {
        var s = HandSkeletonSmoother()
        s.observe(frame { _ in CGPoint(x: 0, y: 0) }, at: 0)
        _ = s.sample(at: 0)
        s.observe(frame { _ in CGPoint(x: 1, y: 1) }, at: 10)
        #expect(s.sample(at: 10)[0] == CGPoint(x: 0, y: 0))
    }

    @Test func aZeroTimeConstantFollowsExactly() {
        var s = HandSkeletonSmoother(timeConstant: 0)
        s.observe(frame { _ in CGPoint(x: 0.3, y: 0.3) }, at: 0)
        _ = s.sample(at: 0)
        s.observe(frame { _ in CGPoint(x: 0.6, y: 0.6) }, at: 0.01)
        #expect(s.sample(at: 0.01)[0] == HandSkeleton.selfie(CGPoint(x: 0.6, y: 0.6)))
    }

    @Test func resetForgetsEveryJoint() {
        var s = HandSkeletonSmoother()
        s.observe(frame { _ in CGPoint(x: 0.5, y: 0.5) }, at: 0)
        _ = s.sample(at: 0)
        s.reset()
        #expect(s.sample(at: 0.01).allSatisfy { $0 == nil })
    }

#if canImport(Vision)
    @Test func theJointListMapsToVisionInTheSameOrder() {
        let expected: [Joint] = [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip,
        ]
        #expect(HandSkeleton.joints.map(\.visionJoint) == expected)
    }

    @Test func theClassifierAdapterCarriesOnlyJointCoordinates() {
        let points = Dictionary(uniqueKeysWithValues: HandSkeleton.joints.enumerated().map { ($1.visionJoint, CGPoint(x: Double($0) / 40, y: 0.5)) })
        let hand = Hand(chirality: .right, points: points, confidence: 0.9)
        let obs = HandClassifierAdapter.observation(from: hand, at: 1, classifier: GestureClassifier())
        #expect(obs.skeleton?.points.count == 21)
        #expect(obs.skeleton?.points[4] == CGPoint(x: 4.0 / 40, y: 0.5))
        let none = HandClassifierAdapter.observation(from: nil, at: 1, classifier: GestureClassifier())
        #expect(none.skeleton == nil)
    }
#endif
}

@Suite struct HandReadingTests {
    private func hand(pose: Pose? = nil, pinch: Double? = nil, present: Bool = true) -> HandObservation {
        HandObservation(t: 0, present: present, pose: pose, palmCenter: nil, pinch: pinch)
    }

    @Test func pinchThresholdMatchesTheGestureMachine() {
        #expect(HandReading.pinchClosed == GestureMachine().pinchClosed)
    }

    @Test func readingsNameWhatTheSystemSees() {
        #expect(HandReading(hand(present: false)) == .noHand)
        #expect(HandReading(hand(pose: .openPalm, pinch: 0.4)) == .openHand)
        #expect(HandReading(hand(pose: .thumbsUp)) == .thumbsUp)
        #expect(HandReading(hand(pose: nil, pinch: 0.05)) == .pinch)
        #expect(HandReading(hand(pose: nil, pinch: 0.3)) == .otherHand)
        #expect(HandReading(hand(pose: .pointUp, pinch: 0.3)) == .pointingUp)
    }

    @Test func aThumbsUpOrFistIsNeverCalledAPinchEvenWithTouchingFingertips() {
        #expect(HandReading(hand(pose: .thumbsUp, pinch: 0.05)) == .thumbsUp)
        #expect(HandReading(hand(pose: .fist, pinch: 0.05)) == .fist)
    }

    @Test func aHeldThumbsUpShowsHowLongAfterTwoTenthsOfASecond() {
        var tracker = HandReadoutTracker()
        let up = hand(pose: .thumbsUp)
        #expect(tracker.observe(up, at: 1.0) == "Thumbs-up")
        #expect(tracker.observe(up, at: 1.15) == "Thumbs-up")
        #expect(tracker.observe(up, at: 1.4) == "Thumbs-up held 0.4 s")
        // A different reading restarts the clock.
        #expect(tracker.observe(hand(pose: .openPalm), at: 1.5) == "Open hand")
        #expect(tracker.observe(up, at: 1.6) == "Thumbs-up")
    }

    @Test func otherPosesNeverShowAHoldTime() {
        var tracker = HandReadoutTracker()
        let open = hand(pose: .openPalm)
        _ = tracker.observe(open, at: 0)
        #expect(tracker.observe(open, at: 5) == "Open hand")
        #expect(tracker.observe(hand(present: false), at: 6) == "No hand")
    }
}
