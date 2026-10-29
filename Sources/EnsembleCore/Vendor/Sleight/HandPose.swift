#if canImport(Vision) && canImport(CoreMedia)
import Vision
import CoreMedia

public typealias Joint = VNHumanHandPoseObservation.JointName

/// One detected hand: normalized landmark positions (origin bottom-left, 0...1).
public struct Hand {
    public let chirality: VNChirality
    public let points: [Joint: CGPoint]
    public let confidence: Float

    public init(chirality: VNChirality, points: [Joint: CGPoint], confidence: Float) {
        self.chirality = chirality; self.points = points; self.confidence = confidence
    }

    public subscript(_ j: Joint) -> CGPoint? { points[j] }

    /// Bounding-box diagonal of all landmarks, as a fraction of the frame. Grows as the hand
    /// approaches the camera and shrinks when it is foreshortened (e.g. lying flat on a desk).
    public var extent: CGFloat {
        guard points.count >= 5 else { return 0 }
        let xs = points.values.map(\.x), ys = points.values.map(\.y)
        return hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }

    /// Stable reference point for motion tracking. Needs at least three of the five palm joints:
    /// a hand half out of frame or mostly occluded yields one or two, and a "center" that jumps
    /// between them as they flicker looked like a swipe in the idle fixture.
    public var palmCenter: CGPoint? {
        let pts = [Joint.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { points[$0] }
        guard pts.count >= 3 else { return nil }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                       y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }
}

public final class HandPoseDetector {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    public var minJointConfidence: Float = 0.3

    public init() {}

    public func detect(_ buffer: CMSampleBuffer) -> Hand? {
        let handler = VNImageRequestHandler(cmSampleBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first,
              let all = try? obs.recognizedPoints(.all) else { return nil }
        var pts: [Joint: CGPoint] = [:]
        for (joint, p) in all where p.confidence >= minJointConfidence {
            pts[joint] = p.location
        }
        return Hand(chirality: obs.chirality, points: pts, confidence: obs.confidence)
    }
}
#endif
