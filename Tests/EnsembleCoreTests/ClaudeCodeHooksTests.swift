import Foundation
import Testing
@testable import EnsembleCore

@Suite struct ClaudeCodeHooksTests {
    @Test func recordedTurnGoesIdleBusyIdleEnded() throws {
        let url = try #require(Bundle.module.url(forResource: "basic-turn", withExtension: "jsonl",
                                                 subdirectory: "Fixtures/claude-code-terminal"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.compactMap(ClaudeCodeHooks.state(forLine:)) == [.idle, .busy, .busy, .busy, .idle, .ended])
    }

    // The recording has no Notification (print mode never asks for permission), so these lines are built here in the
    // shape of the recorded events; they are not a recording.
    @Test func notificationMeansWaitingExceptTheIdleReminder() {
        let line = #"{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt","message":"x"}"#
        #expect(ClaudeCodeHooks.state(forLine: line) == .waiting)
        #expect(ClaudeCodeHooks.state(forLine: #"{"hook_event_name":"Notification"}"#) == .waiting)
        #expect(ClaudeCodeHooks.state(forLine: #"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#) == .idle)
    }

    @Test func otherLinesChangeNothing() {
        #expect(ClaudeCodeHooks.state(forLine: "not json") == nil)
        #expect(ClaudeCodeHooks.state(forLine: #"{"hook_event_name":"PreCompact"}"#) == nil)
    }
}
