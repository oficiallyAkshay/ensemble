import Testing
@testable import EnsembleCore

@Suite struct ClaudeCodeHooksLineEndingTests {
    @Test(arguments: [
        (#"{"hook_event_name":"PreToolUse"}"#, TerminalAgentState.busy),
        (#"{"hook_event_name":"Stop"}"#, TerminalAgentState.idle),
        (#"{"hook_event_name":"SessionEnd"}"#, TerminalAgentState.ended),
    ])
    func trailingCarriageReturnGivesTheSameState(line: String, expected: TerminalAgentState) {
        #expect(ClaudeCodeHooks.state(forLine: line) == expected)
        #expect(ClaudeCodeHooks.state(forLine: line + "\r") == expected)
    }
}
