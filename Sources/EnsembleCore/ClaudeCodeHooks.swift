import Foundation

/// What a Claude Code session in a terminal is doing, as its own hook events report it.
public enum TerminalAgentState: Equatable, Sendable {
    case idle, busy, waiting, ended
}

/// Reads one Claude Code hook event (the JSON object Claude Code writes to a hook's standard input) and says what
/// state it puts the session in. It only reads: it does not find the terminal, type or interrupt.
public enum ClaudeCodeHooks {
    private struct Event: Decodable {
        let hook_event_name: String
        let notification_type: String?
    }

    /// The state after this event, or nil when the line is not a hook event or the event does not change the state.
    public static func state(forLine line: String) -> TerminalAgentState? {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { return nil }
        switch event.hook_event_name {
        case "SessionStart", "Stop": return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .busy
        // Claude Code also sends this type after a minute of waiting for the next prompt, which is idle, not a question.
        case "Notification": return event.notification_type == "idle_prompt" ? .idle : .waiting
        case "SessionEnd": return .ended
        default: return nil
        }
    }
}
