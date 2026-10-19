import Foundation
import Testing
@testable import EnsembleCore

@MainActor @Suite struct UsageTrackerTests {
    /// A tracker on its own defaults suite and a clock the test moves.
    @MainActor final class Rig {
        var date = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 in GMT
        let suite = "usage-test-" + UUID().uuidString
        let defaults: UserDefaults
        var calendar = Calendar(identifier: .gregorian)
        init() {
            calendar.timeZone = TimeZone(identifier: "GMT")!
            defaults = UserDefaults(suiteName: suite)!
        }
        func tracker(sharing: Bool = true) -> UsageTracker {
            UsageTracker(defaults: defaults, sharing: sharing, appVersion: "1.4.2", macOSVersion: "26.0", calendar: calendar, now: { self.date })
        }
        func advance(days: Double = 0, hours: Double = 0, seconds: Double = 0) {
            date = date.addingTimeInterval(days * 86_400 + hours * 3_600 + seconds)
        }
        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func aNewDayClosesTheOneBefore() {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch); t.count(.gestureAttempted(.pinch)); t.count(.gestureSucceeded(.pinch))
        #expect(t.daysToSend(force: true).isEmpty)          // today is never sent
        rig.advance(days: 1)
        let days = t.daysToSend(force: true)
        #expect(days.map(\.day) == ["2026-10-14"])
        #expect(days.first?.launches == 1)
        #expect(days.first?.gesturesSucceeded["pinch"] == 1)
        #expect(t.todaySoFar.day == "2026-10-15")
    }

    @Test func nothingIsSentUntilTheNoticeHasBeenShown() {
        let rig = Rig()
        let t = UsageTracker(defaults: rig.defaults, sharing: true, disclosed: false, appVersion: "1.4.2", macOSVersion: "26.0",
                             calendar: rig.calendar, now: { rig.date })
        t.count(.launch)
        rig.advance(days: 1)
        #expect(t.daysToSend(force: true).isEmpty)           // a finished day waits for the notice
        t.setDisclosed(true)
        #expect(t.daysToSend(force: true).map(\.day) == ["2026-10-14"])
    }

    @Test func aDayWithNothingInItIsNotReported() {
        let rig = Rig(); let t = rig.tracker()
        t.count(.focusMoved)
        rig.advance(days: 1)
        #expect(t.daysToSend(force: true).isEmpty)
    }

    @Test func aSentDayIsNotSentAgain() {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch)
        rig.advance(days: 1)
        let day = t.daysToSend(force: true)[0].day
        t.markSent(day)
        #expect(t.daysToSend(force: true).isEmpty)
        // Counting resumes on the new day and a later day is reported; the sent one stays gone.
        t.count(.launch)
        rig.advance(days: 1)
        #expect(t.daysToSend(force: true).map(\.day) == ["2026-10-15"])
    }

    @Test func aFailedSendIsAskedForAgainAtTheNextHourlyCheck() {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch)
        rig.advance(days: 1)
        #expect(t.daysToSend().count == 1)                   // the launch check; the send fails and nothing is marked
        rig.advance(seconds: 60)
        #expect(t.daysToSend().isEmpty)                      // no tight retry loop
        rig.advance(seconds: UsagePolicy.checkInterval)
        #expect(t.daysToSend().count == 1)                   // the next hourly check asks again
        rig.advance(seconds: -7_200)
        #expect(t.daysToSend().count == 1)                   // a clock set back does not stall the checks
    }

    @Test func aSummaryOlderThanSevenDaysIsDropped() {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch)                                     // 2026-10-14
        rig.advance(days: 8)                                 // on the 22nd the 14th is 8 days old
        #expect(t.daysToSend(force: true).isEmpty)

        let seven = Rig(); let u = seven.tracker()
        u.count(.launch)
        seven.advance(days: 7)
        #expect(u.daysToSend(force: true).count == 1)        // exactly 7 days old is still kept
    }

    @Test func offDeletesEverythingAndRecordsNothing() throws {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch)
        _ = try t.requestBody(for: t.todaySoFar, writeKey: "k")   // creates the install id
        #expect(rig.defaults.data(forKey: "usageLedger") != nil)
        #expect(rig.defaults.string(forKey: "usageInstallID") != nil)

        t.setSharing(false)
        #expect(rig.defaults.data(forKey: "usageLedger") == nil)
        #expect(rig.defaults.string(forKey: "usageInstallID") == nil)
        t.count(.launch); t.activeTick(); t.activeTick(); t.flush(); t.markSent("2026-10-14"); t.resetInstallID()
        rig.advance(days: 1)
        #expect(t.daysToSend(force: true).isEmpty)
        #expect(rig.defaults.data(forKey: "usageLedger") == nil)
        #expect(rig.defaults.string(forKey: "usageInstallID") == nil)
        t.setSharing(false)                                  // already off: nothing changes

        t.setSharing(true)                                   // on again starts from nothing
        #expect(t.todaySoFar.launches == 0)
    }

    @Test func startingOffClearsWhatAnEarlierRunLeft() {
        let rig = Rig()
        rig.tracker().count(.launch)
        #expect(rig.defaults.data(forKey: "usageLedger") != nil)
        _ = rig.tracker(sharing: false)
        #expect(rig.defaults.data(forKey: "usageLedger") == nil)
    }

    @Test func countsSurviveARelaunch() {
        let rig = Rig()
        rig.tracker().count(.launch)
        let again = rig.tracker()
        again.count(.focusMoved)
        #expect(again.todaySoFar.launches == 1)
        #expect(again.todaySoFar.focusMoves == 1)
        again.flush()
    }

    @Test func aDamagedStoreStartsFresh() {
        let rig = Rig()
        rig.defaults.set(Data("not json".utf8), forKey: "usageLedger")
        #expect(rig.tracker().todaySoFar.launches == 0)
    }

    @Test func installIdIsMadeAtFirstSendKeptAndReset() throws {
        let rig = Rig(); let t = rig.tracker()
        func id(_ data: Data) throws -> String {
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(json["distinct_id"] as? String)
        }
        let preview = try t.requestBody(for: t.todaySoFar, writeKey: "k", preview: true)
        #expect(try id(preview) == "assigned-at-first-send")
        #expect(rig.defaults.string(forKey: "usageInstallID") == nil)

        let first = try id(t.requestBody(for: t.todaySoFar, writeKey: "k"))
        #expect(UUID(uuidString: first) != nil)
        #expect(try id(t.requestBody(for: t.todaySoFar, writeKey: "k")) == first)

        t.resetInstallID()
        let second = try id(t.requestBody(for: t.todaySoFar, writeKey: "k"))
        #expect(UUID(uuidString: second) != nil)
        #expect(second != first)
    }

    @Test func thePreviewIsTheSentBody() throws {
        let rig = Rig(); let t = rig.tracker()
        t.count(.launch); t.count(.sendRefused(.emptyDraft))
        let sent = try t.requestBody(for: t.todaySoFar, writeKey: "k")
        #expect(try t.requestBody(for: t.todaySoFar, writeKey: "k", preview: true) == sent)
    }

    @Test func activeTimeAddsWholeSecondsAndSkipsGaps() {
        let rig = Rig(); let t = rig.tracker()
        t.activeTick()                                        // the first tick only starts the clock
        for _ in 0..<120 { rig.advance(seconds: 1); t.activeTick() }
        #expect(t.todaySoFar.activeSeconds == 120)
        rig.advance(seconds: 0.2); t.activeTick()             // too soon: ignored, the clock is not moved
        #expect(t.todaySoFar.activeSeconds == 120)
        rig.advance(seconds: 30); t.activeTick()              // asleep or away: nothing added
        #expect(t.todaySoFar.activeSeconds == 120)
        rig.advance(seconds: -10); t.activeTick()             // the clock moved back: nothing added
        rig.advance(seconds: 1); t.activeTick()
        #expect(t.todaySoFar.activeSeconds == 121)
    }

    @Test func everyEventKindIsCounted() {
        let rig = Rig(); let t = rig.tracker()
        let events: [UsageEvent] = [.launch, .gestureAttempted(.peace), .gestureSucceeded(.peace), .sendRefused(.busy),
                                    .safetyStop(.noFace), .focusMoved, .cameraFormat(width: 1280, height: 720, fps: 30)]
        events.forEach(t.count)
        let d = t.todaySoFar
        #expect(d.launches == 1 && d.focusMoves == 1)
        #expect(d.gesturesAttempted == ["peace": 1] && d.gesturesSucceeded == ["peace": 1])
        #expect(d.sendsRefused == ["busy": 1] && d.safetyStops == ["no_face": 1])
        #expect((d.cameraWidth, d.cameraHeight, d.cameraFPS) == (1280, 720, 30))
    }

    @Test func ledgerAgeReadsDates() {
        #expect(UsageLedger.age(of: "2026-10-14", on: "2026-10-21") == 7)
        #expect(UsageLedger.age(of: "2026-12-30", on: "2027-01-02") == 3)
        #expect(UsageLedger.age(of: "garbage", on: "2026-10-21") == 0)
    }
}

@Suite struct UsageClassifierTests {
    @Test func sendRefusalsMapFromTheRealRules() {
        #expect(SendRefusal.classify(SendRules.refusal(spokenAgo: nil, inputAge: 100)!) == .nothingDictated)
        #expect(SendRefusal.classify(SendRules.frontRefusal(claudeInFront: false)!) == .notInFront)
        #expect(SendRefusal.classify(SendRules.typedRefusal(spokenAgo: 10, inputAge: 1)!) == .typedOrClicked)
    }

    @Test func sendRefusalsMapFromTheNoticesTheAppShows() {
        let notices: [(String, SendRefusal)] = [
            ("Not sent: You just typed or clicked", .typedOrClicked),
            ("Not sent: The draft is empty", .emptyDraft),
            ("Not sent: Could not read the dictated session's message box", .claudeNotReady),
            ("Not sent: Claude is still generating", .claudeNotReady),
            ("Not sent: Send button is disabled", .claudeNotReady),
            ("Not sent: the dictated session is no longer where it was", .claudeNotReady),
            ("Not sent: the draft changed after the countdown started", .claudeNotReady),
            ("Not sent: composer not found", .claudeNotReady),
            ("Not sent: Another app is using a microphone", .otherMicrophone),
            ("Send ignored: busy (still listening)", .busy),
            ("Send dropped: something else started", .busy),
            ("Send ignored: a step is still in flight", .busy),
            ("Not sent: No face in view", .noFace),
            ("Not sent: Camera is covered", .cameraCovered),
            ("Not sent: The screen is locked", .screenLocked),
            ("Not sent: the stop was not confirmed", .stopUnconfirmed),
            ("Not sent: Ensemble is off", .turnedOff),
            ("Send is off in Settings", .turnedOff),
            ("Not sent: something unforeseen", .other),
        ]
        for (notice, reason) in notices { #expect(SendRefusal.classify(notice) == reason, "\(notice)") }
    }
}
