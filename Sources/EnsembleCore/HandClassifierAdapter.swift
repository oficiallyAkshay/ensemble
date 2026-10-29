import Foundation

#if canImport(Vision)

public enum HandClassifierAdapter {
    /// Maps one Sleight hand reading to a `HandObservation`.
    public static func observation(from hand: Hand?, at t: TimeInterval, classifier: GestureClassifier) -> HandObservation {
        guard let hand else { return HandObservation(t: t, present: false, pose: nil, palmCenter: nil) }
        var pinch: Double?
        if let a = hand[.thumbTip], let b = hand[.indexTip], let w = hand[.wrist], let m = hand[.middleMCP] {
            let palm = hypot(w.x - m.x, w.y - m.y)
            if palm > 0.01 { pinch = Double(hypot(a.x - b.x, a.y - b.y) / palm) }
        }
        let features = classifier.features(hand)
        return HandObservation(t: t, present: true, pose: pose(for: features?.gesture), palmCenter: hand.palmCenter, pinch: pinch,
                                skeleton: HandSkeletonFrame(hand: hand), fingerSpread: features?.fingerSpread,
                                twoUp: features?.twoUp ?? false,
                                gate: features?.tooSmall == true ? .tooFar : features?.angled == true ? .angled : nil)
    }

    static func pose(for gesture: Gesture?) -> Pose? {
        switch gesture {
        case .openPalm: return .openPalm
        case .fist: return .fist
        case .twoFingers: return .twoFingers
        case .thumbsUp: return .thumbsUp
        case .gather: return .gather
        case .pointUp: return .pointUp
        case .pointDown: return .pointDown
        case .none: return nil
        }
    }
}
#endif
