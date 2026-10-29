#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// Where one screen sits relative to the user's head, worked out from that screen's own calibration samples,
/// so a reading taken somewhere other than the calibration spot can be turned into the angles the same aim
/// would have produced AT the calibration spot. The per-screen affine map stays the only thing that turns
/// angles into points; this only decides which angles to feed it.
///
/// The nose is a ray from the head position along the head's forward direction. The screen is a plane that
/// stands upright (its sideways turn is inferred; its backward tilt is not). For a reading at head position
/// p, the ray meets the plane at Q; the angles of the line from the calibration position to Q are what the
/// affine map expects. Camera-space axes (from MediaPipe's matrix): x along the image, y up, z toward where
/// the camera looks from; the forward direction is (cos(pitch) sin(yaw), sin(pitch), cos(pitch) cos(yaw)),
/// the same unit vector the yaw and pitch were taken from, so no axis flip needs to be assumed. Whether
/// screen-right is +x or -x (a mirrored camera) is read from the sign of the fitted map instead.
///
/// First-order limits: no sideways tilt of the head, no backward tilt of the monitor, and the head's
/// forward axis is taken to be the aim (a constant offset between them is absorbed by the affine map at the
/// calibration spot but not when the head moves far).
public struct PositionGeometry: Codable, Equatable, Sendable {
    /// Mean head position over the calibration samples (cm).
    var mean: HeadPosition
    var meanYaw: Double, meanPitch: Double
    /// How the head's reported position moves with its angles while it only turns (cm per radian): turning
    /// swings the face a few centimetres around the neck, and that must not read as the user moving.
    var swayYaw: HeadPosition, swayPitch: HeadPosition
    /// Largest angle distance from the mean over the samples (radians), used to keep the sway model inside
    /// the range it was fitted on.
    var yawHalfRange: Double, pitchHalfRange: Double
    /// The screen's sideways turn about the vertical axis (radians) in camera space, and the distance
    /// (cm) from the mean head position to the screen plane along the plane's normal.
    var theta: Double
    var distance: Double
    /// Root-mean-square gap between the fitted plane and the samples (cm); how well the model explained them.
    var residual: Double

    static let maxResidual = 4.0
    static let minDistance = 15.0, maxDistance = 400.0
    /// A head position farther than this from where the head would be at this aim, beyond the clamp, is cut.
    static let maxDisplacement = 150.0

    // MARK: Fitting

    /// Fits the model to one screen's samples. `sizeCm` is the screen's physical size; `slopeX` and `slopeY`
    /// are the signs of the affine map (point x per yaw, point y per pitch). Nil when any sample lacks a
    /// position, the samples do not span the angles, or the plane does not explain them (then the screen
    /// points as it did before head position existed).
    static func fit(samples: [CalibrationSample], frame: CGRect, sizeCm: CGSize, slopeX: Double, slopeY: Double) -> PositionGeometry? {
        guard samples.count >= 5, frame.width > 0, frame.height > 0, sizeCm.width > 0, sizeCm.height > 0,
              slopeX != 0, slopeY != 0, slopeX.isFinite, slopeY.isFinite else { return nil }
        let positions = samples.compactMap(\.position)
        guard positions.count == samples.count, positions.allSatisfy(\.isFinite) else { return nil }
        let n = Double(samples.count)
        let mean = HeadPosition(x: positions.map(\.x).reduce(0, +) / n, y: positions.map(\.y).reduce(0, +) / n,
                                z: positions.map(\.z).reduce(0, +) / n)
        let my = samples.map(\.yaw).reduce(0, +) / n, mp = samples.map(\.pitch).reduce(0, +) / n
        let dys = samples.map { $0.yaw - my }, dps = samples.map { $0.pitch - mp }

        // Sway: least squares of each position axis on (yaw, pitch), with a light ridge and a physical cap.
        let ridge = 1e-4
        var syy = ridge, spp = ridge, syp = 0.0
        for i in 0..<samples.count { syy += dys[i] * dys[i]; spp += dps[i] * dps[i]; syp += dys[i] * dps[i] }
        let det = syy * spp - syp * syp
        guard det > 0 else { return nil }
        func gains(_ values: [Double]) -> (Double, Double) {
            var sy = 0.0, sp = 0.0
            for i in 0..<values.count { sy += dys[i] * values[i]; sp += dps[i] * values[i] }
            let gy = (sy * spp - sp * syp) / det, gp = (sp * syy - sy * syp) / det
            let cap = 30.0
            return (min(max(gy, -cap), cap), min(max(gp, -cap), cap))
        }
        let gx = gains(positions.map { $0.x - mean.x }), gyv = gains(positions.map { $0.y - mean.y }), gz = gains(positions.map { $0.z - mean.z })

        let dirs = samples.map { forward(yaw: $0.yaw, pitch: $0.pitch) }
        let sx = Double(sizeCm.width) / Double(frame.width)
        let sy = Double(sizeCm.height) / Double(frame.height)
        let xs = samples.map { Double($0.target.x) * sx * (slopeX > 0 ? 1 : -1) }
        // Screen-down in cm is +y when the map's pitch slope is positive (pitch up moves the point down).
        let ys = samples.map { Double($0.target.y) * sy * (slopeY > 0 ? 1 : -1) }

        func cost(theta: Double, h: Double) -> Double {
            let (ux, uz) = (cos(theta), sin(theta))
            let (nx, nz) = (-sin(theta), cos(theta))
            var ex = [Double](), ey = [Double]()
            for i in 0..<samples.count {
                let d = dirs[i], p = positions[i]
                let nd = nx * d.x + nz * d.z
                let hp = h - (nx * (p.x - mean.x) + nz * (p.z - mean.z))
                guard nd > 0.05, hp > 1 else { return .infinity }
                let t = hp / nd
                let hit = (x: p.x + t * d.x, y: p.y + t * d.y, z: p.z + t * d.z)
                ex.append(xs[i] - (hit.x * ux + hit.z * uz))
                ey.append(ys[i] - hit.y)
            }
            let mx = ex.reduce(0, +) / n, my2 = ey.reduce(0, +) / n
            return zip(ex, ey).reduce(0.0) { $0 + ($1.0 - mx) * ($1.0 - mx) + ($1.1 - my2) * ($1.1 - my2) }
        }

        // Coarse grid, then a shrinking pattern search around the best cell.
        var best = (theta: 0.0, h: 70.0, c: Double.infinity)
        var h = minDistance
        while h <= maxDistance {
            var deg = -80.0
            while deg <= 80 {
                let c = cost(theta: deg * .pi / 180, h: h)
                if c < best.c { best = (deg * .pi / 180, h, c) }
                deg += 4
            }
            h *= 1.1
        }
        guard best.c.isFinite else { return nil }
        var stepT = 2.0 * Double.pi / 180, stepH = best.h * 0.06
        for _ in 0..<60 {
            var improved = false
            for (dt, dh) in [(stepT, 0.0), (-stepT, 0), (0, stepH), (0, -stepH), (stepT, stepH), (-stepT, -stepH), (stepT, -stepH), (-stepT, stepH)] {
                let c = cost(theta: best.theta + dt, h: best.h + dh)
                if c < best.c { best = (best.theta + dt, best.h + dh, c); improved = true }
            }
            if !improved { stepT *= 0.5; stepH *= 0.5 }
            if stepT < 1e-7 { break }
        }
        let rms = (best.c / n).squareRoot()
        guard rms <= maxResidual, best.h >= minDistance, best.h <= maxDistance, abs(best.theta) < 82 * .pi / 180 else { return nil }

        return PositionGeometry(
            mean: mean, meanYaw: my, meanPitch: mp,
            swayYaw: HeadPosition(x: gx.0, y: gyv.0, z: gz.0), swayPitch: HeadPosition(x: gx.1, y: gyv.1, z: gz.1),
            yawHalfRange: max(dys.map(abs).max() ?? 0, 0.05) * 1.5, pitchHalfRange: max(dps.map(abs).max() ?? 0, 0.05) * 1.5,
            theta: best.theta, distance: best.h, residual: rms)
    }

    // MARK: Evaluating

    static func forward(yaw: Double, pitch: Double) -> HeadPosition {
        HeadPosition(x: cos(pitch) * sin(yaw), y: sin(pitch), z: cos(pitch) * cos(yaw))
    }

    /// Where the head would be, for these angles, had it only turned at the calibration spot.
    func referencePosition(yaw: Double, pitch: Double) -> HeadPosition {
        let dy = min(max(yaw - meanYaw, -yawHalfRange), yawHalfRange)
        let dp = min(max(pitch - meanPitch, -pitchHalfRange), pitchHalfRange)
        return HeadPosition(x: mean.x + swayYaw.x * dy + swayPitch.x * dp,
                            y: mean.y + swayYaw.y * dy + swayPitch.y * dp,
                            z: mean.z + swayYaw.z * dy + swayPitch.z * dp)
    }

    /// The yaw and pitch that, from the calibration spot, aim at the same screen point the reading aims at
    /// from `position`. Nil when the reading points away from this screen's plane. `position` is first
    /// limited to a plausible distance from the calibration spot.
    func equivalentAngles(position: HeadPosition, yaw: Double, pitch: Double) -> (yaw: Double, pitch: Double)? {
        guard position.isFinite, yaw.isFinite, pitch.isFinite else { return nil }
        let d = Self.forward(yaw: yaw, pitch: pitch)
        let (nx, nz) = (-sin(theta), cos(theta))
        var angles = (yaw: yaw, pitch: pitch)
        var moved = false
        // The reference position depends on the angles it produces, which are the answer: a few passes settle it.
        for _ in 0..<4 {
            let ref = referencePosition(yaw: angles.yaw, pitch: angles.pitch)
            let dx = clampDisplacement(position.x - ref.x), dy = clampDisplacement(position.y - ref.y), dz = clampDisplacement(position.z - ref.z)
            if dx * dx + dy * dy + dz * dz < 1e-18 { return moved ? angles : (yaw, pitch) }
            let nd = nx * d.x + nz * d.z
            let hp = distance - (nx * dx + nz * dz)
            guard nd > 0.05, hp > 1 else { return nil }
            let t = hp / nd
            let q = HeadPosition(x: dx + t * d.x, y: dy + t * d.y, z: dz + t * d.z)
            let len = (q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
            guard len > 1e-6, q.z > 0 else { return nil }
            angles = (atan2(q.x, q.z), asin(min(max(q.y / len, -1), 1)))
            moved = true
        }
        return angles
    }

    private func clampDisplacement(_ v: Double) -> Double { min(max(v, -Self.maxDisplacement), Self.maxDisplacement) }
}

/// Smooths and screens the head position stream: rejects a face that is lost or jumps, and applies a light
/// One Euro filter so the correction adds little jitter. Tuned light (1 Hz floor, fast follow) because
/// turning the head also swings the reported position, and a heavy filter would lag behind the angles.
struct HeadPositionTracker {
    static let maxJump = 20.0          // cm between consecutive accepted readings
    static let maxGap = 1.0            // s without a reading before the filter restarts
    static let rejectsBeforeReseed = 10

    private var fx = OneEuroFilter(minCutoff: 1.0, beta: 0.3, dCutoff: 1)
    private var fy = OneEuroFilter(minCutoff: 1.0, beta: 0.3, dCutoff: 1)
    private var fz = OneEuroFilter(minCutoff: 1.0, beta: 0.3, dCutoff: 1)
    private var lastRaw: HeadPosition?
    private var lastT = -Double.infinity
    private var smoothed: HeadPosition?
    private var rejects = 0

    /// Whether a position can be a head at all: finite, and a face that is neither on the lens nor across the room.
    static func isPlausible(_ p: HeadPosition) -> Bool {
        p.isFinite && abs(p.x) < 300 && abs(p.y) < 300 && abs(p.z) > 10 && abs(p.z) < 400
    }

    mutating func reset() {
        fx.reset(); fy.reset(); fz.reset()
        lastRaw = nil; smoothed = nil; rejects = 0; lastT = -.infinity
    }

    /// The smoothed position to use for this reading, or nil when there is none worth using.
    mutating func update(_ position: HeadPosition?, at t: Double) -> HeadPosition? {
        guard t.isFinite else { return smoothed }
        guard let position, Self.isPlausible(position) else { return t - lastT <= Self.maxGap ? smoothed : nil }
        if let prev = lastRaw, t - lastT <= Self.maxGap {
            let jump = ((position.x - prev.x) * (position.x - prev.x) + (position.y - prev.y) * (position.y - prev.y)
                        + (position.z - prev.z) * (position.z - prev.z)).squareRoot()
            if jump > Self.maxJump {
                rejects += 1
                if rejects < Self.rejectsBeforeReseed { return smoothed }
                reset()
            }
        } else {
            reset()
        }
        rejects = 0
        lastRaw = position; lastT = t
        let out = HeadPosition(x: fx.filter(position.x, at: t), y: fy.filter(position.y, at: t), z: fz.filter(position.z, at: t))
        smoothed = out
        return out
    }
}
