import Foundation
import Testing
@testable import EnsembleCore

@Suite struct TerminalClaudeCodeAdapterTests {
    @Test func recordedTurnShowsTheSessionAppearBusyIdleAndEnded() async throws {
        let url = try #require(Bundle.module.url(forResource: "basic-turn", withExtension: "jsonl",
                                                 subdirectory: "Fixtures/claude-code-terminal"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let adapter = TerminalClaudeCodeAdapter()
        #expect(await adapter.refreshSessions(watched: false).sessions.isEmpty)

        var seen: [TerminalAgentState?] = []
        var id: String?
        for line in lines {
            adapter.ingest([line])
            id = await adapter.refreshSessions(watched: false).sessions.first?.id
            seen.append(id.flatMap(adapter.state(of:)))
        }
        #expect(seen == [.idle, .busy, .busy, .busy, .idle, .ended])
        #expect(await adapter.refreshSessions(watched: false).sessions.map(\.id) == [id])
    }

    // Built here in the shape of the recorded events; the recording has no Notification.
    @Test func sessionsAreKeptApartAndLinesWithoutOneAreIgnored() async {
        let adapter = TerminalClaudeCodeAdapter()
        adapter.ingest([
            #"{"session_id":"a","hook_event_name":"UserPromptSubmit"}"#,
            #"{"session_id":"b","hook_event_name":"Notification","notification_type":"permission_prompt"}"#,
            #"{"session_id":"a","hook_event_name":"PreCompact"}"#,
            #"{"hook_event_name":"Stop"}"#,
            "not json",
        ])
        #expect(adapter.state(of: "a") == .busy)
        #expect(adapter.state(of: "b") == .waiting)
        #expect(adapter.state(of: "c") == nil)
        #expect(await adapter.refreshSessions(watched: true).sessions.map(\.id) == ["a", "b"])
    }

    @Test func everyMemberThatActsRefuses() async {
        let adapter = TerminalClaudeCodeAdapter()
        let s = ClaudeSession(id: "a", frame: .zero, windowNumber: 0)
        let refused = BridgeResult.refused("terminal Claude Code is read-only")
        #expect(await adapter.focus(s, unlessTypedWithin: 1) == refused)
        #expect(await adapter.startDictation(s) == refused)
        #expect(await adapter.stopDictation(s) == refused)
        #expect(await adapter.stopAnyDictation() == refused)
        #expect(await adapter.sendDraft(s, shown: "x", stoppedAt: Date(), inputAge: { 0 }) == refused)
        #expect(await adapter.micState(s) == .unknown("terminal Claude Code is read-only"))
        #expect(await adapter.focusComposerIfNeeded(s) == "terminal Claude Code is read-only")
        #expect(adapter.micSnapshot == "terminal Claude Code is read-only")
        #expect(await adapter.draftText(s) == nil)
        #expect(await adapter.paneFrame(s) == nil)
        #expect(await adapter.paneDividers(in: s).isEmpty)
        #expect(await adapter.focusDivider(NSObject(), in: s) == false)
        #expect(await adapter.dividerHoldsKeyboard(NSObject()) == false)
        #expect(await adapter.keyboardOnDivider([NSObject()]) == nil)
        #expect(await adapter.chatColumns(in: [s]).isEmpty)
    }

    @Test func theAppAndItsMicrophoneAreNotThere() {
        let adapter = TerminalClaudeCodeAdapter()
        adapter.beginShutdown()
        adapter.startWorkspaceWatch()
        #expect(adapter.claudePID == nil && adapter.claudeVersion == nil)
        #expect(!adapter.claudeIsRunning() && !adapter.claudeIsFrontmost() && !adapter.accessibilityDisabled)
        #expect(adapter.claudeCaptureActive() == nil && adapter.otherProcessCapturingInput() == nil)
        #expect(adapter.defaultInputDeviceName() == nil && adapter.onSessionsChanged == nil)
    }
}
