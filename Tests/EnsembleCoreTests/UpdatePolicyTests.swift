import Testing
@testable import EnsembleCore

@Suite struct UpdatePolicyTests {
    @Test func checksHourly() {
        #expect(UpdatePolicy.checkInterval == 3600)
    }

    @Test func checksAtLaunchOnlyWhenTurnedOnAndSetUp() {
        #expect(UpdatePolicy.checksAtLaunch(configured: true, automatic: true))
        #expect(!UpdatePolicy.checksAtLaunch(configured: true, automatic: false))
        #expect(!UpdatePolicy.checksAtLaunch(configured: false, automatic: true))
    }

    @Test func buttonOffersTheNewVersion() {
        #expect(UpdatePolicy.buttonState(available: "0.2.11", showingUpToDate: false).title == "Update to 0.2.11")
        #expect(UpdatePolicy.buttonState(available: "0.2.11", showingUpToDate: true).title == "Update to 0.2.11")
    }

    @Test func buttonSaysUpToDateBrieflyThenChecks() {
        #expect(UpdatePolicy.buttonState(available: nil, showingUpToDate: true).title == "Up to date")
        #expect(UpdatePolicy.buttonState(available: nil, showingUpToDate: false).title == "Check for Updates")
    }

    @Test func idleStatesNeverSpin() {
        #expect(!UpdatePolicy.buttonState(available: nil, showingUpToDate: false).spinning)
        #expect(!UpdatePolicy.buttonState(available: nil, showingUpToDate: true).spinning)
        #expect(!UpdatePolicy.buttonState(available: "0.2.11", showingUpToDate: false).spinning)
    }

    @Test func checkingSpins() {
        #expect(UpdatePolicy.buttonState(available: nil, showingUpToDate: false, checking: true)
                == UpdateButtonState(title: "Checking...", spinning: true))
    }

    @Test func downloadingSpinsAndShowsThePercentOnceKnown() {
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, installing: "0.3.0", downloading: true)
                == UpdateButtonState(title: "Downloading 0.3.0", spinning: true))
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, installing: "0.3.0", downloading: true,
                                         downloadPercent: 42) == UpdateButtonState(title: "Downloading 0.3.0 (42%)", spinning: true))
    }

    @Test func downloadingWhileBusyStillShowsTheDownload() {
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, installing: "0.3.0", waitingForIdle: true,
                                         downloading: true, downloadPercent: 7).title == "Downloading 0.3.0 (7%)")
    }

    @Test func installingSpinsAndWaitingDoesNot() {
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, installing: "0.3.0")
                == UpdateButtonState(title: "Installing 0.3.0...", spinning: true))
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, installing: "0.3.0", waitingForIdle: true)
                == UpdateButtonState(title: "Installs 0.3.0 when you finish", spinning: false))
    }

    @Test func failureOffersRetryWithoutSpinning() {
        #expect(UpdatePolicy.buttonState(available: "0.3.0", showingUpToDate: false, failed: true)
                == UpdateButtonState(title: "Update failed. Retry", spinning: false))
        #expect(UpdatePolicy.buttonState(available: nil, showingUpToDate: false, failed: true).title == "Update failed. Retry")
    }

    @Test func aNewCheckReplacesTheFailure() {
        #expect(UpdatePolicy.buttonState(available: nil, showingUpToDate: false, checking: true, failed: true).title == "Checking...")
    }

    @Test func theButtonWalksThroughAWholeUpdate() {
        // check -> found -> go-ahead -> download (size unknown, then known) -> unpacking -> installing -> nothing running
        let steps: [(UpdateButtonState, String, Bool)] = [
            (UpdatePolicy.buttonState(available: nil, showingUpToDate: false, checking: true), "Checking...", true),
            (UpdatePolicy.buttonState(available: "1.0.0", showingUpToDate: false), "Update to 1.0.0", false),
            (UpdatePolicy.buttonState(available: "1.0.0", showingUpToDate: false, installing: "1.0.0", downloading: true),
             "Downloading 1.0.0", true),
            (UpdatePolicy.buttonState(available: "1.0.0", showingUpToDate: false, installing: "1.0.0", downloading: true,
                                      downloadPercent: 100), "Downloading 1.0.0 (100%)", true),
            (UpdatePolicy.buttonState(available: "1.0.0", showingUpToDate: false, installing: "1.0.0"), "Installing 1.0.0...", true),
            (UpdatePolicy.buttonState(available: nil, showingUpToDate: false), "Check for Updates", false),
        ]
        for (state, title, spinning) in steps {
            #expect(state.title == title)
            #expect(state.spinning == spinning)
        }
    }

    @Test func downloadPercentIsUnknownWithoutASize() {
        #expect(UpdatePolicy.downloadPercent(received: 500, expected: 0) == nil)
    }

    @Test func downloadPercentIsWholeAndNeverAboveAHundred() {
        #expect(UpdatePolicy.downloadPercent(received: 0, expected: 1000) == 0)
        #expect(UpdatePolicy.downloadPercent(received: 429, expected: 1000) == 42)
        #expect(UpdatePolicy.downloadPercent(received: 1000, expected: 1000) == 100)
        #expect(UpdatePolicy.downloadPercent(received: 1500, expected: 1000) == 100)
    }
}
