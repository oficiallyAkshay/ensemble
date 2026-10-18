import Foundation
import Testing
@testable import EnsembleCore

@Suite struct UpdateFlowTests {
    // MARK: UpdateOffer

    @Test func pressingUpdateToInstallsWithoutAsking() {
        let offer = UpdateOffer.decide(version: "1.0", installRequested: true, userInitiated: true, automatic: false, declined: ["1.0"])
        #expect(offer == .install)
    }

    @Test func checkForUpdatesAsksOnceEvenAfterLater() {
        let offer = UpdateOffer.decide(version: "1.0", installRequested: false, userInitiated: true, automatic: true, declined: ["1.0"])
        #expect(offer == .ask)
    }

    @Test func automaticUpdatesNeverAsk() {
        let offer = UpdateOffer.decide(version: "1.0", installRequested: false, userInitiated: false, automatic: true, declined: [])
        #expect(offer == .install)
    }

    @Test func backgroundFindAsksOncePerVersionWithAutomaticOff() {
        #expect(UpdateOffer.decide(version: "1.0", installRequested: false, userInitiated: false, automatic: false, declined: []) == .ask)
        #expect(UpdateOffer.decide(version: "1.0", installRequested: false, userInitiated: false, automatic: false, declined: ["1.0"]) == .quiet)
        #expect(UpdateOffer.decide(version: "1.1", installRequested: false, userInitiated: false, automatic: false, declined: ["1.0"]) == .ask)
    }

    @Test func pressingTheButtonWithAKnownVersionInstallsWithoutAPrompt() {
        let press = UpdatePress.decide(availableVersion: "1.1")
        #expect(press == .install(version: "1.1"))
        // The find that follows the press is the go-ahead, even though Sparkle reports it as user initiated.
        let offer = UpdateOffer.decide(version: "1.1", installRequested: press != .check, userInitiated: true, automatic: false, declined: [])
        #expect(offer == .install)
    }

    @Test func pressingTheButtonWithNoKnownVersionChecks() {
        #expect(UpdatePress.decide(availableVersion: nil) == .check)
    }

    // MARK: UpdateRelaunch

    @Test func noRecordMeansNothing() {
        #expect(UpdateRelaunch.decide(pending: nil, installedVersion: "1.0", loginAgentOn: true, startedByLoginAgent: false) == .nothing)
    }

    @Test func announcesTheInstalledVersion() {
        let pending = PendingUpdate(version: "1.1")
        #expect(UpdateRelaunch.decide(pending: pending, installedVersion: "1.1", loginAgentOn: false, startedByLoginAgent: false) == .announce("1.1"))
        #expect(UpdateRelaunch.decide(pending: pending, installedVersion: "1.1", loginAgentOn: true, startedByLoginAgent: true) == .announce("1.1"))
    }

    @Test func anUpdateThatDidNotLandIsReported() {
        let pending = PendingUpdate(version: "1.1")
        #expect(UpdateRelaunch.decide(pending: pending, installedVersion: "1.0", loginAgentOn: true, startedByLoginAgent: false) == .notInstalled("1.1"))
    }

    @Test func handsOverToTheLoginAgentOnlyOnce() {
        let first = PendingUpdate(version: "1.1")
        #expect(UpdateRelaunch.decide(pending: first, installedVersion: "1.1", loginAgentOn: true, startedByLoginAgent: false) == .handOverToLoginAgent)
        let second = PendingUpdate(version: "1.1", handedOver: true)
        #expect(UpdateRelaunch.decide(pending: second, installedVersion: "1.1", loginAgentOn: true, startedByLoginAgent: false) == .announce("1.1"))
    }

    // MARK: IdleGate

    @Test func idleGateNeedsUnbrokenIdleTime() {
        var gate = IdleGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(!gate.idle(for: 0, at: t0))
        gate.observe(busy: false, at: t0)
        #expect(gate.idle(for: 0, at: t0))
        #expect(!gate.idle(for: 30, at: t0.addingTimeInterval(29)))
        gate.observe(busy: false, at: t0.addingTimeInterval(20))
        #expect(gate.idle(for: 30, at: t0.addingTimeInterval(30)))
        gate.observe(busy: true, at: t0.addingTimeInterval(31))
        #expect(!gate.idle(for: 0, at: t0.addingTimeInterval(31)))
        gate.observe(busy: false, at: t0.addingTimeInterval(40))
        #expect(!gate.idle(for: 30, at: t0.addingTimeInterval(60)))
        #expect(gate.idle(for: 30, at: t0.addingTimeInterval(70)))
    }

    @Test func theQuestionWaitsForTheKeyboardToRest() {
        #expect(!UpdatePolicy.offerMayShow(idle: true, secondsSinceKey: 0.5))
        #expect(!UpdatePolicy.offerMayShow(idle: true, secondsSinceKey: UpdatePolicy.offerTypingQuiet - 0.1))
        #expect(UpdatePolicy.offerMayShow(idle: true, secondsSinceKey: UpdatePolicy.offerTypingQuiet))
        #expect(UpdatePolicy.offerMayShow(idle: true, secondsSinceKey: .infinity))
        #expect(!UpdatePolicy.offerMayShow(idle: false, secondsSinceKey: .infinity))
    }

    // MARK: Text and links

    @Test func offerAsksTheOneQuestion() {
        #expect(UpdatePolicy.offerMessage(version: "0.3.0") == "Ensemble 0.3.0 is available. Install now?")
    }

    @Test func menuBarBadgeShowsOnlyWhileAVersionIsKnown() {
        #expect(UpdatePolicy.showsUpgradeBadge(available: "0.3.0"))
        #expect(!UpdatePolicy.showsUpgradeBadge(available: nil))
        #expect(!UpdatePolicy.showsUpgradeBadge(available: ""))
    }

    @Test func buttonShowsInstallProgressAndWaiting() {
        #expect(UpdatePolicy.buttonTitle(available: "0.3.0", showingUpToDate: false, installing: "0.3.0") == "Installing 0.3.0...")
        #expect(UpdatePolicy.buttonTitle(available: "0.3.0", showingUpToDate: false, installing: "0.3.0", waitingForIdle: true)
                == "Installs 0.3.0 when you finish")
        #expect(UpdatePolicy.buttonTitle(available: nil, showingUpToDate: false, checking: true) == "Checking...")
    }

    @Test func whatsNewPrefersTheFeedsOwnLinks() {
        let notes = URL(string: "https://example.org/notes")!
        let info = URL(string: "https://example.org/info")!
        #expect(UpdatePolicy.releaseNotesLink(fullNotes: nil, notes: notes, info: info, download: nil) == notes)
        #expect(UpdatePolicy.releaseNotesLink(fullNotes: nil, notes: nil, info: info, download: nil) == info)
    }

    @Test func whatsNewFallsBackToTheReleasePage() {
        let download = URL(string: "https://example.org/owner/app/releases/download/v0.3.0/App-0.3.0.dmg")!
        #expect(UpdatePolicy.releaseNotesLink(fullNotes: nil, notes: nil, info: nil, download: download)
                == URL(string: "https://example.org/owner/app/releases/tag/v0.3.0"))
        let other = URL(string: "https://example.org/files/App.dmg")!
        #expect(UpdatePolicy.releaseNotesLink(fullNotes: nil, notes: nil, info: nil, download: other) == nil)
        #expect(UpdatePolicy.releaseNotesLink(fullNotes: nil, notes: nil, info: nil, download: nil) == nil)
    }
}
