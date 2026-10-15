import Testing
@testable import EnsembleCore

@Suite struct TrackerRetryTests {
    @Test func theFirstFailureRetriesAtOnce() {
        var retry = TrackerRetry()
        #expect(retry.nextDelay() == 0)
        #expect(retry.failures == 1)
    }

    @Test func theWaitDoublesWithEachFailureAndStopsAtTheCap() {
        var retry = TrackerRetry()
        let delays = (0..<8).map { _ in retry.nextDelay() }
        #expect(delays == [0, 2, 4, 8, 16, 30, 30, 30])
        #expect(retry.failures == 8)
    }

    @Test func itNeverGivesUp() {
        var retry = TrackerRetry()
        for _ in 0..<10_000 { _ = retry.nextDelay() }
        #expect(retry.nextDelay() == TrackerRetry.cap)
    }

    @Test func aResetStartsOverAtTheFirstWait() {
        var retry = TrackerRetry()
        for _ in 0..<5 { _ = retry.nextDelay() }
        retry.reset()
        #expect(retry.failures == 0)
        #expect(retry.nextDelay() == 0)
        #expect(retry.nextDelay() == 2)
    }
}
