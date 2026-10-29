#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

public enum EdgeSide: Equatable, Sendable { case left, right, top, bottom }

/// What the nose is approaching while it leaves the dictating session: which edge, what lies beyond it
/// (a neighbouring Claude session, or nothing of Claude's), how far through the outer band it has moved,
/// and whether it is already outside.
public struct EdgeWarning: Equatable, Sendable {
    public var side: EdgeSide
    /// The neighbouring session beyond the edge; nil when what lies beyond is not Claude.
    public var neighbourId: String?
    /// 0...1 through the outer band of the dictating session toward `side`.
    public var proximity: Double
    /// The nose is outside the dictating session on `side`.
    public var crossed: Bool
    /// The stretch of the edge the warning concerns, along the edge (y for left and right, x for top and bottom):
    /// the part shared with the neighbour, or the whole edge when nothing of Claude's lies beyond.
    public var seamStart: CGFloat
    public var seamEnd: CGFloat

    /// The seam as two points on `frame`'s edge, from its lower coordinate to its higher one.
    public func seam(in frame: CGRect) -> (CGPoint, CGPoint) {
        switch side {
        case .left: return (CGPoint(x: frame.minX, y: seamStart), CGPoint(x: frame.minX, y: seamEnd))
        case .right: return (CGPoint(x: frame.maxX, y: seamStart), CGPoint(x: frame.maxX, y: seamEnd))
        case .top: return (CGPoint(x: seamStart, y: frame.minY), CGPoint(x: seamEnd, y: frame.minY))
        case .bottom: return (CGPoint(x: seamStart, y: frame.maxY), CGPoint(x: seamEnd, y: frame.maxY))
        }
    }
}

/// Pure geometry for the warnings shown while dictating: what lies beyond the edge the nose approaches, and
/// whether a look has gone deep enough into a neighbour to count as resting on it.
public enum EdgeWarnings {
    /// The outer share of the dictating session (per axis) in which the warning builds up.
    public static let band: CGFloat = 0.15
    /// While dictating, the nose must be this share of the neighbour's width (height, for a neighbour above or
    /// below) inside it before it counts as resting there.
    public static let neighbourDepth: CGFloat = 0.15

    /// Which side of `frame` the other frame lies on: the axis along which they are furthest apart relative to
    /// their sizes decides.
    public static func side(of other: CGRect, from frame: CGRect) -> EdgeSide {
        let dx = other.midX - frame.midX, dy = other.midY - frame.midY
        let nx = abs(dx) / max((frame.width + other.width) / 2, 1)
        let ny = abs(dy) / max((frame.height + other.height) / 2, 1)
        if nx >= ny { return dx < 0 ? .left : .right }
        return dy < 0 ? .top : .bottom
    }

    /// The warning for this nose position, nil while the nose is in the inner part of the session.
    public static func warning(nose p: CGPoint, dictating: ClaudeSession, sessions: [ClaudeSession]) -> EdgeWarning? {
        let f = dictating.frame
        guard f.width > 0, f.height > 0, p.x.isFinite, p.y.isFinite else { return nil }
        let bw = f.width * band, bh = f.height * band
        let raws: [(EdgeSide, CGFloat, Bool)] = [
            (.left, (f.minX + bw - p.x) / bw, p.x < f.minX),
            (.right, (p.x - (f.maxX - bw)) / bw, p.x > f.maxX),
            (.top, (f.minY + bh - p.y) / bh, p.y < f.minY),
            (.bottom, (p.y - (f.maxY - bh)) / bh, p.y > f.maxY),
        ]
        var best = raws[0]
        for r in raws.dropFirst() where r.1 > best.1 { best = r }
        guard best.1 > 0 else { return nil }
        let edge = best.0, crossed = best.2
        let proximity = Double(min(best.1, 1))

        let others = sessions.filter { $0.id != dictating.id && side(of: $0.frame, from: f) == edge }
        func perp(_ r: CGRect) -> ClosedRange<CGFloat> {
            edge == .left || edge == .right ? r.minY...r.maxY : r.minX...r.maxX
        }
        func gap(_ r: CGRect) -> CGFloat {
            switch edge {
            case .left: return abs(f.minX - r.maxX)
            case .right: return abs(r.minX - f.maxX)
            case .top: return abs(f.minY - r.maxY)
            case .bottom: return abs(r.minY - f.maxY)
            }
        }
        let along = edge == .left || edge == .right ? p.y : p.x
        var neighbour = others.filter { perp($0.frame).contains(along) }.min { gap($0.frame) < gap($1.frame) }
        // Once outside, the session actually under the nose is the one being approached.
        if crossed, let under = sessions.first(where: { $0.id != dictating.id && $0.frame.contains(p) }) { neighbour = under }

        let own = perp(f)
        if let n = neighbour {
            let theirs = perp(n.frame)
            let lo = max(own.lowerBound, theirs.lowerBound), hi = min(own.upperBound, theirs.upperBound)
            if hi > lo {
                return EdgeWarning(side: edge, neighbourId: n.id, proximity: proximity, crossed: crossed, seamStart: lo, seamEnd: hi)
            }
        }
        return EdgeWarning(side: edge, neighbourId: nil, proximity: proximity, crossed: crossed,
                           seamStart: own.lowerBound, seamEnd: own.upperBound)
    }

    /// Whether the nose is deep enough inside `neighbour` for a look to count as resting on it.
    public static func restsDeepInside(nose p: CGPoint, neighbour: CGRect, dictating: CGRect) -> Bool {
        switch side(of: neighbour, from: dictating) {
        case .right: return p.x - neighbour.minX >= neighbour.width * neighbourDepth
        case .left: return neighbour.maxX - p.x >= neighbour.width * neighbourDepth
        case .bottom: return p.y - neighbour.minY >= neighbour.height * neighbourDepth
        case .top: return neighbour.maxY - p.y >= neighbour.height * neighbourDepth
        }
    }
}

/// Whether the person is speaking, from the input level, so a glance away in mid-sentence does not switch
/// sessions. It needs the level meter, which runs only with the optional microphone permission; without it
/// the lock is never active.
public struct SpeechLock: Equatable, Sendable {
    /// Input level (0...1, -55 dB to -12 dB) above which the person counts as speaking.
    public static let threshold = 0.3
    /// Quiet this long before the lock lets go.
    public static let quiet: TimeInterval = 0.6

    private var active = false
    private var lastLoud: TimeInterval?

    public init() {}

    /// A level reading from a running meter.
    public mutating func note(level: Double, at t: TimeInterval) {
        active = true
        if level > Self.threshold { lastLoud = t }
    }

    /// The meter stopped: no level is known, so nothing is locked.
    public mutating func meterStopped() { active = false; lastLoud = nil }

    public func locked(at t: TimeInterval) -> Bool {
        guard active, let l = lastLoud else { return false }
        return t - l < Self.quiet
    }
}
