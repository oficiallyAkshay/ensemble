import CoreGraphics
import Foundation

/// A divider between two side-by-side panes. `element` is the adapter's own reference to it (for the Claude desktop
/// app, its Accessibility element): the coordinator hands it back to the adapter and never looks inside.
public struct PaneDivider: @unchecked Sendable {
    public let element: AnyObject
    public let frame: CGRect
    /// The lower limit of the pair's split, in percent of the pair, as the app reports it.
    public let minPercent: Double?
    public init(element: AnyObject, frame: CGRect, minPercent: Double?) {
        self.element = element; self.frame = frame; self.minPercent = minPercent
    }
}

/// Everything the coordinator and its controllers ask of the app that runs the sessions: find sessions, focus, read
/// state, send text, panes. The Claude desktop app is the only adapter. The members keep the names and meanings they
/// had on the Claude bridge they were taken from; the Accessibility work behind them stays in the app target. Only
/// the coordinator decides to press an adapter's controls.
public protocol AgentAdapter: AnyObject, Sendable {
    // The app
    var claudePID: pid_t? { get }
    var claudeVersion: String? { get }
    func claudeIsRunning() -> Bool
    func claudeIsFrontmost() -> Bool
    /// True when the last discovery was refused because Accessibility is off or the grant is stale.
    var accessibilityDisabled: Bool { get }
    /// Once called, no new dictation can start.
    func beginShutdown()
    /// Both microphone sources as of the last read, for logs; never touches Accessibility.
    var micSnapshot: String { get }
    func claudeCaptureActive() -> Bool?
    func otherProcessCapturingInput() -> String?
    func defaultInputDeviceName() -> String?

    // Sessions
    func startWorkspaceWatch()
    /// Called on the main actor when the app's windows or panes changed.
    var onSessionsChanged: (@MainActor () -> Void)? { get set }
    func refreshSessions(watched: Bool) async -> (sessions: [ClaudeSession], recording: Set<String>)
    func paneFrame(_ s: ClaudeSession) async -> CGRect?
    func focus(_ s: ClaudeSession, unlessTypedWithin quiet: TimeInterval) async -> BridgeResult
    func focusComposerIfNeeded(_ s: ClaudeSession) async -> String

    // Dictation and send
    func micState(_ s: ClaudeSession) async -> MicState
    func startDictation(_ s: ClaudeSession) async -> BridgeResult
    func stopDictation(_ s: ClaudeSession) async -> BridgeResult
    func stopAnyDictation() async -> BridgeResult
    func draftText(_ s: ClaudeSession) async -> String?
    func sendDraft(_ s: ClaudeSession, shown: String, stoppedAt: Date, inputAge: @escaping @Sendable () -> Double) async -> BridgeResult

    // Panes
    func paneDividers(in s: ClaudeSession) async -> [PaneDivider]
    func focusDivider(_ divider: AnyObject, in s: ClaudeSession) async -> Bool
    func dividerHoldsKeyboard(_ divider: AnyObject) async -> Bool
    func keyboardOnDivider(_ dividers: [AnyObject]) async -> Bool?
    func chatColumns(in sessions: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)]
}
