import Foundation
import Testing
@testable import EnsembleCore

@Suite struct DotVelocityTests {
    @Test func zeroHasNoComponentsAndEqualsItself() {
        #expect(DotVelocity.zero == DotVelocity(dx: 0, dy: 0))
        #expect(DotVelocity.zero.dx == 0)
        #expect(DotVelocity.zero.dy == 0)
    }

    @Test func springVelocityCarriesBothAxesAndClearsToZero() {
        var spring = DotSpring()
        spring.reset(to: CGPoint(x: 0, y: 0))
        spring.step(toward: CGPoint(x: 100, y: -50), dt: 1.0 / 60)
        #expect(spring.velocity != .zero)
        #expect(spring.velocity.dx > 0)
        #expect(spring.velocity.dy < 0)
        spring.clear()
        #expect(spring.velocity == .zero)
    }
}
