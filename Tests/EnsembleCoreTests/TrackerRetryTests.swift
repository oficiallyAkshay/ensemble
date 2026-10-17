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

    @Test func aGoodReadingCancelsTheWaitingRetry() throws {
        var retry = TrackerRetry()
        #expect(retry.failed() == 0)
        #expect(retry.failed() == 2)
        let waiting = try #require(retry.waiting)
        retry.reset()
        #expect(retry.waiting == nil)
        let due = retry.due(waiting)
        #expect(!due)
    }

    @Test func anImmediateRestartLeavesNoEarlierRetryDue() throws {
        var retry = TrackerRetry()
        _ = retry.failed()
        _ = retry.failed()
        let earlier = try #require(retry.waiting)
        retry.reset()
        #expect(retry.failed() == 0)
        #expect(retry.waiting == nil)
        let due = retry.due(earlier)
        #expect(!due)
    }

    @Test func aWaitingRetryIsDueOnce() throws {
        var retry = TrackerRetry()
        _ = retry.failed()
        _ = retry.failed()
        let waiting = try #require(retry.waiting)
        let first = retry.due(waiting)
        let second = retry.due(waiting)
        #expect(first)
        #expect(!second)
        #expect(retry.waiting == nil)
    }

    @Test func aSecondReportWhileTheRetryWaitsCountsNothing() throws {
        var retry = TrackerRetry()
        _ = retry.failed()
        #expect(retry.failed() == 2)
        #expect(retry.failed() == nil)
        #expect(retry.failures == 2)
        let due = retry.due(try #require(retry.waiting))
        #expect(due)
        #expect(retry.failed() == 4)
    }
}
