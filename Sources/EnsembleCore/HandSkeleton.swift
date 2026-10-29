#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// The 21 hand joints Vision reports, as bare coordinates: what the tour's inset draws. No image ever comes
/// through here, only normalized points, so the engine hands the tour a skeleton and nothing else of the frame.
public struct HandSkeletonFrame: Sendable, Equatable {
    /// One slot per joint in `HandSkeleton.joints` order. Normalized image coordinates, origin bottom-left, 0...1.
    /// nil when Vision did not report that joint with enough confidence.
    public var points: [CGPoint?]

    public init(points: [CGPoint?]) {
        precondition(points.count == HandSkeleton.joints.count, "a hand skeleton has \(HandSkeleton.joints.count) joints")
        self.points = points
    }

#if canImport(Vision)
    public init(hand: Hand) {
        self.init(points: HandSkeleton.joints.map { hand[$0] })
    }
#endif
}

public enum HandSkeleton {
    /// Wrist, then each finger from its base to its tip (thumb, index, middle, ring, little).
    public static let joints: [Joint] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// Indexes into `joints`, 21 bones: each finger's joints chain to its tip, the wrist joins the thumb, index and
    /// little finger, and the index, middle, ring and little bases join across the palm (so the middle and ring
    /// fingers hang from the palm line rather than from separate wrist spokes).
    public static let bones: [(from: Int, to: Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (9, 10), (10, 11), (11, 12),
        (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20),
        (5, 9), (9, 13), (13, 17),
    ]

    /// A point in the camera's normalized space (origin bottom-left) as it should be drawn in a unit square with
    /// its origin at the top-left, flipped left to right like a mirror, so the user's right hand is on the right.
    public static func selfie(_ p: CGPoint) -> CGPoint {
        CGPoint(x: 1 - p.x, y: 1 - p.y)
    }

    /// The bones whose two joints are both present, ready to stroke.
    public static func segments(of points: [CGPoint?]) -> [(CGPoint, CGPoint)] {
        guard points.count == joints.count else { return [] }
        return bones.compactMap { bone in
            guard let a = points[bone.from], let b = points[bone.to] else { return nil }
            return (a, b)
        }
    }
}

/// Eases drawn joints toward the newest readings so a 30 Hz hand looks continuous at display rate. Positions are
/// in the selfie unit square (see `HandSkeleton.selfie`). A joint Vision drops for a moment keeps its last place
/// for `holdAfterLoss` seconds, so a flickering fingertip does not blink; a hand that leaves fades from the
/// drawing once all its joints have expired. Not thread-safe.
public struct HandSkeletonSmoother {
    /// Time constant of the exponential ease, in seconds: after this long a joint has covered 63% of the gap.
    public var timeConstant: TimeInterval
    public var holdAfterLoss: TimeInterval

    private var target: [CGPoint?]
    private var shown: [CGPoint?]
    private var seen: [TimeInterval]
    private var lastSample: TimeInterval?

    public init(timeConstant: TimeInterval = 0.05, holdAfterLoss: TimeInterval = 0.25) {
        self.timeConstant = timeConstant
        self.holdAfterLoss = holdAfterLoss
        let n = HandSkeleton.joints.count
        target = Array(repeating: nil, count: n)
        shown = Array(repeating: nil, count: n)
        seen = Array(repeating: -.infinity, count: n)
    }

    /// A new reading at time `t`, or nil when no hand was found in the frame.
    public mutating func observe(_ frame: HandSkeletonFrame?, at t: TimeInterval) {
        guard let frame else { return }
        for (i, p) in frame.points.enumerated() {
            guard let p else { continue }
            target[i] = HandSkeleton.selfie(p)
            seen[i] = t
        }
    }

    /// The joints to draw at time `now`; nil entries are not drawn.
    public mutating func sample(at now: TimeInterval) -> [CGPoint?] {
        let dt = lastSample.map { max(0, now - $0) } ?? .infinity
        lastSample = now
        // A long gap (the window was hidden) snaps instead of sweeping across the inset.
        let k: Double = (dt > 0.5 || timeConstant <= 0) ? 1 : 1 - exp(-dt / timeConstant)
        for i in shown.indices {
            guard let goal = target[i], now - seen[i] <= holdAfterLoss else {
                shown[i] = nil
                target[i] = nil
                continue
            }
            if let current = shown[i] {
                shown[i] = CGPoint(x: current.x + (goal.x - current.x) * k, y: current.y + (goal.y - current.y) * k)
            } else {
                shown[i] = goal
            }
        }
        return shown
    }

    public mutating func reset() {
        self = HandSkeletonSmoother(timeConstant: timeConstant, holdAfterLoss: holdAfterLoss)
    }
}

/// What the system currently reads from the hand, in words, for the line under the tour's skeleton inset.
public enum HandReading: Equatable, Sendable {
    case noHand, pinch, thumbsUp, openHand, fist, twoFingers, gather, pointingUp, pointingDown, otherHand

    /// Thumb tip to index tip, in palm lengths, below which the hand reads as pinched. Same value as the gesture
    /// machine's `pinchClosed`, which a test keeps in step.
    public static let pinchClosed = 0.12

    public init(_ hand: HandObservation) {
        guard hand.present else { self = .noHand; return }
        if hand.pose == .thumbsUp { self = .thumbsUp; return }
        if let pinch = hand.pinch, pinch < Self.pinchClosed, hand.pose != .fist { self = .pinch; return }
        switch hand.pose {
        case .openPalm: self = .openHand
        case .fist: self = .fist
        case .twoFingers: self = .twoFingers
        case .gather: self = .gather
        case .pointUp: self = .pointingUp
        case .pointDown: self = .pointingDown
        case .thumbsUp: self = .thumbsUp
        case nil: self = .otherHand
        }
    }

    public var title: String {
        switch self {
        case .noHand: return "No hand"
        case .pinch: return "Pinch"
        case .thumbsUp: return "Thumbs-up"
        case .openHand: return "Open hand"
        case .fist: return "Fist"
        case .twoFingers: return "Two fingers"
        case .gather: return "Gather"
        case .pointingUp: return "Pointing up"
        case .pointingDown: return "Pointing down"
        case .otherHand: return "Hand"
        }
    }

    /// The two readings the gestures hold on: the pinch of dictate and scroll, and the thumbs-up of send.
    var isHeldGesture: Bool { self == .pinch || self == .thumbsUp }
}

/// Words for the current reading, with how long a held pinch or thumbs-up has lasted ("Thumbs-up held 0.4 s").
public struct HandReadoutTracker {
    /// A hold shows only after this long, so a passing reading does not flash a time.
    public static let showHoldAfter: TimeInterval = 0.2

    private var reading = HandReading.noHand
    private var since: TimeInterval = 0

    public init() {}

    public mutating func observe(_ hand: HandObservation, at t: TimeInterval) -> String {
        let now = HandReading(hand)
        if now != reading { reading = now; since = t }
        let held = t - since
        guard reading.isHeldGesture, held >= Self.showHoldAfter else { return reading.title }
        return "\(reading.title) held \(String(format: "%.1f", held)) s"
    }

    public mutating func reset() {
        self = HandReadoutTracker()
    }
}
