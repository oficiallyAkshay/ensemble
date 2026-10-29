#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// One head reading taken while a calibration dot is showing. Angles are radians, as the face tracker reports them.
public struct AimReading: Equatable, Sendable {
    public var t: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public init(t: TimeInterval, yaw: Double, pitch: Double) { self.t = t; self.yaw = yaw; self.pitch = pitch }
}

/// What a head must have done before a calibration dot counts as looked at. The sample for a dot is only
/// worth taking when the head has turned toward it and is holding still: eyes alone do not move the head
/// angles, so a sample taken without that would pair the dot with the wrong head position.
public enum AimRequirement: Equatable, Sendable {
    /// Hold still; nothing is known about where the head came from (the very first dot).
    case stillness
    /// Hold still, and have moved from `from` in the direction of the target on each axis whose sign is not 0
    /// (+1: the angle must have grown by at least the minimum, -1: shrunk by at least the minimum).
    case movedToward(fromYaw: Double, fromPitch: Double, yawSign: Int, pitchSign: Int, minYaw: Double, minPitch: Double)
}

public enum AimVerdict: Equatable, Sendable {
    /// Not enough readings yet, or the head is still moving.
    case notStill
    /// Still and the right way, but not far enough.
    case notFarEnough
    /// Still and moved toward the dot; the head angles to pair with it.
    case ready(yaw: Double, pitch: Double)
}

/// The acceptance rule for a calibration point, with every number it uses. Pure logic: no camera, no UI.
public struct AimRule: Sendable {
    /// The head must hold within `maxSpread` (max minus min, per axis) for this long.
    public var stableSeconds = 0.4
    public var maxSpread = 0.03
    /// Once held, the ring fills over this long, taking the readings that arrive meanwhile.
    public var fillSeconds = 0.9
    /// After this long without the head arriving, the text asks for the head to move, not the eyes.
    public var nudgeAfter = 4.0
    /// After this long the point is offered as Skip / Retry instead of waiting any longer.
    public var giveUpAfter = 12.0
    /// Yaw grows as the head turns toward the right of the screen; pitch grows as it tips down. These are the
    /// conventions the pointer fit in `NosePointerTests` uses; flip them here if a camera reports the other way.
    public var yawIncreasesRight = true
    public var pitchIncreasesDown = true
    /// Smallest turn ever demanded, whatever the geometry says.
    public var yawFloor = 0.04
    public var pitchFloor = 0.03
    /// The share of the expected turn that must be seen.
    public var shareOfExpectedTurn = 0.4
    /// Expected turn across a whole screen before any sample on it gives a better estimate.
    public var assumedYawPerScreenWidth = 0.5
    public var assumedPitchPerScreenHeight = 0.3
    /// A target step smaller than this share of the screen's width or height is not an expected turn on that axis.
    public var meaningfulStep = 0.1
    /// Between screens, the centres must be apart by at least this share of the larger screen's side to expect a turn.
    public var meaningfulScreenStep = 0.25
    public var yawFloorBetweenScreens = 0.08
    public var pitchFloorBetweenScreens = 0.05

    public init() {}

    // MARK: Requirements

    /// The requirement for a dot after the first on a screen. `accepted` are the samples already taken on this
    /// screen (the last one is the previous dot); their spread gives the turn per point actually seen.
    public func requirement(forTarget target: CGPoint, on frame: CGRect, accepted: [CalibrationSample]) -> AimRequirement {
        guard let previous = accepted.last, frame.width > 0, frame.height > 0 else { return .stillness }
        let dx = Double(target.x - previous.target.x), dy = Double(target.y - previous.target.y)
        let yawPerPoint = Self.slope(accepted, angle: \.yaw, along: \.x) ?? assumedYawPerScreenWidth / Double(frame.width)
        let pitchPerPoint = Self.slope(accepted, angle: \.pitch, along: \.y) ?? assumedPitchPerScreenHeight / Double(frame.height)

        var yawSign = 0, pitchSign = 0, minYaw = 0.0, minPitch = 0.0
        if abs(dx) >= meaningfulStep * Double(frame.width) {
            yawSign = (dx > 0) == yawIncreasesRight ? 1 : -1
            minYaw = max(yawFloor, shareOfExpectedTurn * yawPerPoint * abs(dx))
        }
        if abs(dy) >= meaningfulStep * Double(frame.height) {
            pitchSign = (dy > 0) == pitchIncreasesDown ? 1 : -1
            minPitch = max(pitchFloor, shareOfExpectedTurn * pitchPerPoint * abs(dy))
        }
        if yawSign == 0, pitchSign == 0 { return .stillness }
        return .movedToward(fromYaw: previous.yaw, fromPitch: previous.pitch, yawSign: yawSign, pitchSign: pitchSign,
                            minYaw: minYaw, minPitch: minPitch)
    }

    /// The requirement for the first dot on a screen. For the second and later screens the head must have turned
    /// from where the previous screen's centre dot was taken toward this screen's side of the desk.
    public func requirement(forFirstDotOn frame: CGRect, previousScreen: (frame: CGRect, centre: CalibrationSample)?) -> AimRequirement {
        guard let previousScreen else { return .stillness }
        let dx = Double(frame.midX - previousScreen.frame.midX), dy = Double(frame.midY - previousScreen.frame.midY)
        let wide = Double(max(frame.width, previousScreen.frame.width)), tall = Double(max(frame.height, previousScreen.frame.height))
        var yawSign = 0, pitchSign = 0, minYaw = 0.0, minPitch = 0.0
        if abs(dx) >= meaningfulScreenStep * wide {
            yawSign = (dx > 0) == yawIncreasesRight ? 1 : -1
            minYaw = yawFloorBetweenScreens
        }
        if abs(dy) >= meaningfulScreenStep * tall, abs(dy) > abs(dx) {
            pitchSign = (dy > 0) == pitchIncreasesDown ? 1 : -1
            minPitch = pitchFloorBetweenScreens
        }
        if yawSign == 0, pitchSign == 0 { return .stillness }
        return .movedToward(fromYaw: previousScreen.centre.yaw, fromPitch: previousScreen.centre.pitch,
                            yawSign: yawSign, pitchSign: pitchSign, minYaw: minYaw, minPitch: minPitch)
    }

    /// Absolute angle change per point of target travel, from the samples that differ most along `axis`.
    private static func slope(_ samples: [CalibrationSample], angle: KeyPath<CalibrationSample, Double>,
                              along axis: KeyPath<CGPoint, CGFloat>) -> Double? {
        guard let low = samples.min(by: { $0.target[keyPath: axis] < $1.target[keyPath: axis] }),
              let high = samples.max(by: { $0.target[keyPath: axis] < $1.target[keyPath: axis] }) else { return nil }
        let span = Double(high.target[keyPath: axis] - low.target[keyPath: axis])
        guard span > 1 else { return nil }
        let value = abs(high[keyPath: angle] - low[keyPath: angle]) / span
        return value.isFinite && value > 0 ? value : nil
    }

    // MARK: Verdict

    /// The last `stableSeconds` of `readings`, when they cover that long, number at least four and stay within
    /// `maxSpread`; their mean. Nil otherwise.
    public func stableMean(_ readings: [AimReading]) -> (yaw: Double, pitch: Double)? {
        guard let last = readings.last else { return nil }
        let window = readings.filter { $0.t >= last.t - stableSeconds }
        guard window.count >= 4, let first = window.first, last.t - first.t >= stableSeconds * 0.8 else { return nil }
        let yaws = window.map(\.yaw), pitches = window.map(\.pitch)
        guard let yMin = yaws.min(), let yMax = yaws.max(), let pMin = pitches.min(), let pMax = pitches.max(),
              yMax - yMin <= maxSpread, pMax - pMin <= maxSpread else { return nil }
        let n = Double(window.count)
        return (yaws.reduce(0, +) / n, pitches.reduce(0, +) / n)
    }

    public func evaluate(_ readings: [AimReading], requirement: AimRequirement) -> AimVerdict {
        guard let mean = stableMean(readings) else { return .notStill }
        guard case let .movedToward(fromYaw, fromPitch, yawSign, pitchSign, minYaw, minPitch) = requirement else {
            return .ready(yaw: mean.yaw, pitch: mean.pitch)
        }
        var short = false
        for (sign, change, minimum) in [(yawSign, mean.yaw - fromYaw, minYaw), (pitchSign, mean.pitch - fromPitch, minPitch)] where sign != 0 {
            // The tracker's angle signs are not verified against a live head, so only the size of the turn counts:
            // a head that has not moved enough is refused, whichever way the angles happen to grow.
            if abs(change) < minimum { short = true }
        }
        return short ? .notFarEnough : .ready(yaw: mean.yaw, pitch: mean.pitch)
    }
}

public enum AimHint: Equatable, Sendable {
    case turnToDot
    case moveHead
}

public enum AimState: Equatable, Sendable {
    case waiting(AimHint)
    case filling(progress: Double)
    case captured(yaw: Double, pitch: Double)
    /// `giveUpAfter` passed without the head arriving: offer Skip / Retry.
    case timedOut
}

/// One calibration dot's acceptance, over time. Feed it readings as they arrive and ask for the state with the
/// current time (the same clock as the readings). Pure: it owns no timer.
public struct AimGate: Sendable {
    public let rule: AimRule
    public let requirement: AimRequirement
    private var startedAt: TimeInterval
    private var readings: [AimReading] = []
    private var fillStart: TimeInterval?
    private var fillAnchor: (yaw: Double, pitch: Double)?
    private var result: (yaw: Double, pitch: Double)?

    /// A reading older than this at the moment of asking means the face was lost.
    private static let staleAfter = 0.6

    public init(rule: AimRule = AimRule(), requirement: AimRequirement, startedAt: TimeInterval) {
        self.rule = rule; self.requirement = requirement; self.startedAt = startedAt
    }

    public mutating func push(_ reading: AimReading) {
        guard reading.yaw.isFinite, reading.pitch.isFinite else { return }
        readings.append(reading)
        if readings.count > 120 { readings.removeFirst(readings.count - 120) }
    }

    /// Starts the clock again for the same dot (Retry).
    public mutating func restart(at now: TimeInterval) {
        startedAt = now; readings = []; fillStart = nil; fillAnchor = nil; result = nil
    }

    public mutating func update(now: TimeInterval) -> AimState {
        if let result { return .captured(yaw: result.yaw, pitch: result.pitch) }
        let fresh = (readings.last?.t).map { now - $0 <= Self.staleAfter } ?? false

        if let start = fillStart, let anchor = fillAnchor {
            let during = readings.filter { $0.t >= start }
            let drifted = during.contains { abs($0.yaw - anchor.yaw) > rule.maxSpread || abs($0.pitch - anchor.pitch) > rule.maxSpread }
            if !fresh || drifted {
                fillStart = nil; fillAnchor = nil
            } else if now - start >= rule.fillSeconds, during.count >= 6 {
                let n = Double(during.count)
                let mean = (yaw: during.map(\.yaw).reduce(0, +) / n, pitch: during.map(\.pitch).reduce(0, +) / n)
                result = mean
                return .captured(yaw: mean.yaw, pitch: mean.pitch)
            } else {
                return .filling(progress: min(max((now - start) / rule.fillSeconds, 0), 1))
            }
        }

        if fresh, case .ready(let yaw, let pitch) = rule.evaluate(readings, requirement: requirement) {
            fillStart = now; fillAnchor = (yaw, pitch)
            return .filling(progress: 0)
        }
        let waited = now - startedAt
        if waited >= rule.giveUpAfter { return .timedOut }
        return .waiting(waited >= rule.nudgeAfter ? .moveHead : .turnToDot)
    }
}
