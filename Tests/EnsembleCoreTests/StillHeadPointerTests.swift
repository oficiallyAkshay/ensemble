import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A head that does not move must leave the dot where it is. While the picture is still the camera engine hands on
/// the last reading ten times a second and sends one real reading a second (`StillFace`); these replay that stream
/// through the pointer and the resting dot.
@Suite struct StillHeadPointerTests {
    private static let aim = CGPoint(x: 1280, y: 720)
    /// Points. Small natural tremor is fine; the jump in the report was about two inches.
    private static let tolerance = 10.0

    /// Largest distance from the first dot position over `seconds`. `offset(second)` is the yaw error (radians) of
    /// that second's real reading; the readings between are the same one handed on again.
    private static func wander(seconds: Int, offset: (Int) -> Double) -> Double {
        let pointer = Desk.calibratedPointer()
        var rest = NoseDot()
        var first: CGPoint?
        var worst = 0.0
        for i in 0..<(seconds * 10) {
            let fresh = i % 10 == 0
            var r = Desk.reading(head: (0, 0, 70), target: Desk.desk(main: aim), t: Double(i) / 10)
            r.yaw += offset(i / 10)
            guard let nose = pointer.point(for: r) else { continue }
            let dot = rest.follow(nose: nose, at: r.t, fresh: fresh)
            first = first ?? dot
            worst = max(worst, Double(hypot(dot.x - first!.x, dot.y - first!.y)))
        }
        return worst
    }

    @Test func aConstantReadingHoldsTheDotForThirtySeconds() {
        #expect(Self.wander(seconds: 30) { _ in 0 } <= Self.tolerance)
    }

    @Test func anIsolatedRealReadingEveryFewSecondsDoesNotMoveTheDot() {
        // One real reading in three is 0.03 rad (about 2 cm at 70 cm) off; the rest are right. Handed on again
        // ten times, that one reading used to wake the dot and carry it there.
        #expect(Self.wander(seconds: 30) { $0 % 3 == 1 ? 0.03 : 0 } <= Self.tolerance)
    }
}
