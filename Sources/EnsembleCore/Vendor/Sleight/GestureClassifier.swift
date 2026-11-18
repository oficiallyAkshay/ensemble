import Foundation
#if canImport(Vision)
import Vision

public enum Gesture: String, CaseIterable {
    case openPalm, fist, twoFingers, thumbsUp
    case gather                  // Ensemble: all fingertips together
    case pointUp, pointDown      // Ensemble change: index finger out, pointing up or down
}

/// Everything the classifier derived from one hand, for the debug view.
public struct HandFeatures {
    public var index, middle, ring, little: Bool
    public var curled: Int              // fingers folded back past their PIP (see `GestureClassifier.curlRatio`)
    public var tipReach: CGFloat        // farthest fingertip from the wrist, in palm lengths
    public var thumbStraight, thumbClear, thumbUp: Bool
    public var extent: CGFloat          // landmark bounding-box diagonal, fraction of frame
    public var palm: CGFloat            // wrist → middle MCP, fraction of frame; the unit every finger test is normalized by
    public var span: CGFloat            // knuckle width (index MCP → little MCP) in palm lengths; see `maxPalmSpan`
    public var upright: CGFloat         // middle knuckle above the wrist, in palm lengths; see `minUpright`
    public var tooSmall: Bool           // pose rejected because the hand is too far away
    public var angled: Bool             // pose rejected because the palm does not face the camera or points down
    public var indexRise: CGFloat = 0   // Ensemble change: index tip above its MCP, in palm lengths (negative = pointing down)
    public var fingerSpread: Double?    // Ensemble change: index tip to middle tip, in palm lengths; see `WidthGestures`
    /// Ensemble change: index and middle out, ring and little folded, before the distance and angle gates. Only the
    /// two-fingers diagnostics read it, so a peace sign the gates refuse still shows up in the log.
    public var twoUp = false
    public var thumb: Bool { thumbStraight && thumbClear }
    public var extendedCount: Int { [index, middle, ring, little].filter { $0 }.count }
    /// Enough fingers extended to count as an open hand; swipes only track open hands.
    public var isOpen: Bool { extendedCount >= 3 }
    public var gesture: Gesture?
}

/// Rule-based static pose classifier on Vision hand landmarks.
/// All distances are normalized by hand size (wrist → middle MCP) for scale invariance.
public struct GestureClassifier {
    public init() {}

    /// Open-finger poses (open palm, two fingers) need at least this hand extent. Deliberate open
    /// palms measure 0.33 at arm's length and 0.21 one step back; the floor only rejects hands
    /// farther than that. Distance no longer separates gestures from desk hands (an open hand
    /// held up while talking reaches 0.29), `maxPalmSpan` does.
    public var minOpenExtent: CGFloat = 0.19
    /// Closed poses (fist, thumbs up) need this much. A fist is compact, about 0.6 of an open
    /// palm's extent at the same distance: 0.19 at arm's length, 0.12 one step back.
    public var minClosedExtent: CGFloat = 0.11
    /// Ensemble change: two fingers (the peace sign) needs this much. A V is as tall as an open palm but about half as
    /// wide, so the same hand reads roughly 0.9 of an open palm's extent: an open palm one step back measures 0.21, a
    /// V there about 0.19, right on the open floor. The recorded idle and desk hands add 18 two-fingers frames
    /// between 0.15 and 0.19 and none of them holds a spread that acts (see `WidthGestures`).
    public var minTwoFingersExtent: CGFloat = 0.15

    /// Knuckle width over palm length, at most, for open palm, fist and two fingers. A palm facing
    /// the camera keeps its full wrist-to-knuckle length and measures 0.37–0.58 in every fixture at
    /// both distances. A hand on the desk or gesturing while talking is seen at an angle, its palm
    /// length foreshortens and the ratio grows: 0.64–0.72 for the open hand that fired at extent
    /// 0.22, 0.6–1.9 for idle hands generally. Every size-normalized finger test above also
    /// assumes an unforeshortened palm, so this is the precondition for trusting them. Thumbs up is
    /// exempt: the hand is edge-on by nature (1.3–1.7).
    static let maxPalmSpan: CGFloat = 0.6

    /// A finger is extended when its tip reaches past 1.15× its PIP distance from the wrist, and
    /// curled when it folds back inside 0.85×. In between is a relaxed finger: a hand on a mouse or
    /// keyboard is all relaxed fingers (idle fixture: ratios 0.84–1.15) and used to read as a fist,
    /// while every deliberate fist, thumbs up and two-fingers frame folds its closed fingers to
    /// 0.41–0.84. Closed poses therefore require curled fingers, not merely non-extended ones.
    static let extendRatio: CGFloat = 1.15
    static let curlRatio: CGFloat = 0.85

    /// A fist also keeps every fingertip inside the palm: within this many palm lengths of the
    /// wrist (fixture fists 0.61–0.77 at both distances). Fingers hanging over a mouse or keyboard
    /// curl past their PIP too, but from beyond the knuckles (0.99–1.28), and a relaxed closed hand
    /// resting on the desk sits between (dogfood fixtures: 0.81–0.90 for their whole hold). Thumbs
    /// up is exempt: the hand is turned edge-on, so its folded fingers project past the knuckles
    /// (1.05–1.43).
    static let fistTipReach: CGFloat = 0.8
    /// Ensemble change: a fist held up close to the camera (extent >= `closeFistExtent`) gets looser limits.
    /// Measured live on a MacBook camera: a natural fist read tipReach 0.84–0.91 and a tucked-thumb fist span
    /// 0.63–0.64, both at extent 0.32–0.50. The relaxed closed hand on the desk that the original 0.8 guards
    /// against (dogfood fixture, tipReach 0.81–0.95) sits at extent 0.12–0.13, so it keeps the strict limits.
    static let gatherMaxSpread: CGFloat = 0.6
    static let gatherMinReach: CGFloat = 1.0
    static let closeFistExtent: CGFloat = 0.2
    static let closeFistTipReach: CGFloat = 0.95
    static let closeFistMaxPalmSpan: CGFloat = 0.7

    /// An open palm's fingertips reach at most this many palm lengths from the wrist: a finger is
    /// about one palm long, so a camera-facing open hand measures 1.8–2.0 (fixtures at both
    /// distances: median 1.85–2.03, p95 ≤ 2.08). A hand pitched about its knuckle axis (resting on
    /// the desk, seen from above) foreshortens the palm but not the fingers and reads 2.1–3.0; the
    /// span gate cannot see pitch, only yaw. Dogfood open-palm misfires: median 2.18–2.92.
    static let maxOpenTipReach: CGFloat = 2.1

    /// The middle knuckle must sit this many palm lengths above the wrist: a gesture made toward
    /// the camera is upright. Every fixture pose measures ≥ 0.97, thumbs up (edge-on) ≥ 0.46. The
    /// right hand resting at the frame edge points its fingers down (dogfood: -0.5 to -1.0) and
    /// a fifth of the idle fixture's hands do too.
    static let minUpright: CGFloat = 0.3

    /// Ensemble change: pointing. Index extended, middle/ring/little curled, thumb ignored. The index tip must sit
    /// at least this many palm lengths above (pointUp) or below (pointDown) its MCP in the image, otherwise the
    /// finger points at the camera or sideways and there is no pose. Exempt from `minUpright` (a hand pointing
    /// down is not upright), but not from the extent floor or the span gate.
    static let pointMinRise: CGFloat = 0.5

    /// Ensemble change: two fingers needs ring and little folded at least this far (tip inside this many PIP
    /// distances from the wrist), not fully curled. With the thumb holding them down they curl to 0.34-0.56 (the
    /// recorded two-fingers hold); with the thumb out they only fold loosely, often past `curlRatio` (0.85), which
    /// refused every V made with the thumb out. Requiring 1.0, short of `extendRatio`, keeps a nearly straight ring
    /// or little finger out. No recorded open palm, fist, thumbs-up or idle hand gains a two-fingers frame from it.
    static let twoFingersFoldRatio: CGFloat = 1.0

    public func classify(_ hand: Hand) -> Gesture? { features(hand)?.gesture }

    public func features(_ hand: Hand) -> HandFeatures? {
        guard let wrist = hand[.wrist], let midMCP = hand[.middleMCP] else { return nil }
        let size = dist(wrist, midMCP)
        guard size > 0.01 else { return nil }

        // Tip distance from the wrist relative to the PIP's: >1.15 extended, <0.85 curled.
        func reach(tip: Joint, pip: Joint) -> CGFloat? {
            guard let t = hand[tip], let p = hand[pip] else { return nil }
            let d = dist(p, wrist)
            return d > 0 ? dist(t, wrist) / d : nil
        }
        guard let index = reach(tip: .indexTip, pip: .indexPIP),
              let middle = reach(tip: .middleTip, pip: .middlePIP),
              let ring = reach(tip: .ringTip, pip: .ringPIP),
              let little = reach(tip: .littleTip, pip: .littlePIP),
              let indexTip = hand[.indexTip],
              let thumbTip = hand[.thumbTip], let thumbIP = hand[.thumbIP],
              let indexMCP = hand[.indexMCP], let littleMCP = hand[.littleMCP]
        else { return nil }
        let reaches = [index, middle, ring, little]
        let ext = reaches.map { $0 > Self.extendRatio }
        let curl = reaches.map { $0 < Self.curlRatio }
        let folded = reaches.map { $0 < Self.twoFingersFoldRatio }
        let tipReach = [Joint.indexTip, .middleTip, .ringTip, .littleTip]
            .compactMap { hand[$0] }.map { dist($0, wrist) / size }.max() ?? 0

        // Thumb: extended when straight and clear of the index knuckle (a tucked thumb sits on it).
        let thumbStraight = dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.1
        let thumbClear = dist(thumbTip, indexMCP) / size > 0.6
        var f = HandFeatures(index: ext[0], middle: ext[1], ring: ext[2], little: ext[3],
                             curled: curl.filter { $0 }.count, tipReach: tipReach,
                             thumbStraight: thumbStraight, thumbClear: thumbClear,
                             thumbUp: thumbTip.y > indexMCP.y + 0.3 * size,
                             extent: hand.extent, palm: size, span: dist(indexMCP, littleMCP) / size,
                             upright: (midMCP.y - wrist.y) / size, tooSmall: false, angled: false)
        f.indexRise = (indexTip.y - indexMCP.y) / size
        if let middleTip = hand[.middleTip] { f.fingerSpread = Double(dist(indexTip, middleTip) / size) }
        f.twoUp = ext[0] && ext[1] && folded[2] && folded[3]
        let n = f.extendedCount
        // Ensemble change: "gather" = all five fingertips brought together, fingers forward (not curled into a fist).
        // Measured live: gathered tips spread 0.33–0.55 palm lengths with the tip centroid 1.07–1.38 from the wrist;
        // an open palm spreads 0.9–1.4, a fist keeps its tips within 0.57–0.86 of the wrist.
        let tipPts = [Joint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip].compactMap { hand[$0] }
        var gathered = false
        if tipPts.count == 5 {
            var spread: CGFloat = 0
            for i in 0..<5 { for j in (i + 1)..<5 { spread = max(spread, dist(tipPts[i], tipPts[j])) } }
            let c = CGPoint(x: tipPts.map(\.x).reduce(0, +) / 5, y: tipPts.map(\.y).reduce(0, +) / 5)
            gathered = spread / size <= Self.gatherMaxSpread && dist(c, wrist) / size >= Self.gatherMinReach
        }
        // Open palm ignores the thumb: a relaxed palm keeps it alongside the index (measured
        // 0.26–0.47 hand-widths from the index MCP, same range as a fist), so it carries no signal.
        if gathered { f.gesture = .gather }
        else if n == 4 && tipReach <= Self.maxOpenTipReach { f.gesture = .openPalm }
        else if f.curled == 4 && !f.thumb && tipReach < (f.extent >= Self.closeFistExtent ? Self.closeFistTipReach : Self.fistTipReach) { f.gesture = .fist }
        else if f.twoUp { f.gesture = .twoFingers }
        else if f.curled == 4 && f.thumb && f.thumbUp { f.gesture = .thumbsUp }
        else if ext[0] && curl[1] && curl[2] && curl[3] {
            if f.indexRise > Self.pointMinRise { f.gesture = .pointUp }
            else if f.indexRise < -Self.pointMinRise { f.gesture = .pointDown }
        }

        if let g = f.gesture {
            let floor = g == .openPalm ? minOpenExtent : g == .twoFingers ? minTwoFingersExtent : minClosedExtent
            if f.extent < floor { f.tooSmall = true; f.gesture = nil }
            else if (g != .thumbsUp && g != .gather && f.span > (g == .fist && f.extent >= Self.closeFistExtent ? Self.closeFistMaxPalmSpan : Self.maxPalmSpan)) || (f.upright < Self.minUpright && g != .pointUp && g != .pointDown) { f.angled = true; f.gesture = nil }
        }
        return f
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
#endif
