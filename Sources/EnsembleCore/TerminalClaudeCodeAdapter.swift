#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// Shows what Claude Code sessions in a terminal are doing, from the hook event lines it is handed.
///
/// Read-only, and not registered with the coordinator, which keeps using the Claude desktop app's adapter. It lists
/// the sessions it has seen events for and reports each one's state; every member that acts refuses. Registering it,
/// finding the terminal window, typing and interrupting are separate tickets that need a real run on the owner's Mac.
public final class TerminalClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    private struct Event: Decodable { let session_id: String? }

    private let lock = NSLock()
    private var order: [String] = []
    private var states: [String: TerminalAgentState] = [:]

    public init() {}

    /// Applies hook event lines in order. A line with no session, or one that changes no state, is ignored.
    public func ingest(_ lines: [String]) {
        lock.withLock {
            for line in lines {
                guard let id = (try? JSONDecoder().decode(Event.self, from: Data(line.utf8)))?.session_id,
                      let state = ClaudeCodeHooks.state(forLine: line) else { continue }
                if states[id] == nil { order.append(id) }
                states[id] = state
            }
        }
    }

    /// The state of a session, or nil when no event has named it.
    public func state(of id: String) -> TerminalAgentState? {
        lock.withLock { states[id] }
    }

    private static let refusal = "terminal Claude Code is read-only"

    public var claudePID: Int32? { nil }
    public var claudeVersion: String? { nil }
    public func claudeIsRunning() -> Bool { false }
    public func claudeIsFrontmost() -> Bool { false }
    public var accessibilityDisabled: Bool { false }
    public func beginShutdown() {}
    public var micSnapshot: String { Self.refusal }
    public func claudeCaptureActive() -> Bool? { nil }
    public func otherProcessCapturingInput() -> String? { nil }
    public func defaultInputDeviceName() -> String? { nil }

    public func startWorkspaceWatch() {}
    public var onSessionsChanged: (@MainActor () -> Void)?
    /// A terminal session has no window the adapter knows of, so the frame and window number are placeholders.
    public func refreshSessions(watched _: Bool) async -> (sessions: [ClaudeSession], recording: Set<String>) {
        let ids = lock.withLock { order }
        return (ids.map { ClaudeSession(id: $0, frame: .zero, windowNumber: 0) }, [])
    }
    public func paneFrame(_: ClaudeSession) async -> CGRect? { nil }
    public func focus(_: ClaudeSession, unlessTypedWithin _: TimeInterval) async -> BridgeResult { .refused(Self.refusal) }
    public func focusComposerIfNeeded(_: ClaudeSession) async -> String { Self.refusal }

    public func micState(_: ClaudeSession) async -> MicState { .unknown(Self.refusal) }
    public func startDictation(_: ClaudeSession) async -> BridgeResult { .refused(Self.refusal) }
    public func stopDictation(_: ClaudeSession) async -> BridgeResult { .refused(Self.refusal) }
    public func stopAnyDictation() async -> BridgeResult { .refused(Self.refusal) }
    public func draftText(_: ClaudeSession) async -> String? { nil }
    public func sendDraft(_: ClaudeSession, shown _: String, stoppedAt _: Date, inputAge _: @escaping @Sendable () -> Double) async -> BridgeResult {
        .refused(Self.refusal)
    }

    public func paneDividers(in _: ClaudeSession) async -> [PaneDivider] { [] }
    public func focusDivider(_: AnyObject, in _: ClaudeSession) async -> Bool { false }
    public func dividerHoldsKeyboard(_: AnyObject) async -> Bool { false }
    public func keyboardOnDivider(_: [AnyObject]) async -> Bool? { nil }
    public func chatColumns(in _: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)] { [:] }
}
