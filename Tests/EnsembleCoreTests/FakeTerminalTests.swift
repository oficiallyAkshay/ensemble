import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A test double, not a recorded fixture: a terminal that notes what reaches it. Like any adapter that acts, it does
/// nothing unless its app is in front.
private final class FakeTerminal: AgentAdapter, @unchecked Sendable {
    var inFront: Bool
    private(set) var interrupts = 0
    private(set) var typed: [String] = []
    init(inFront: Bool) { self.inFront = inFront }

    func interrupt(_ s: ClaudeSession) async -> BridgeResult {
        guard inFront else { return .refused("the terminal is not in front") }
        interrupts += 1
        return .done
    }
    func typeIntoTerminal(_ s: ClaudeSession, draft: String) async -> BridgeResult {
        guard inFront else { return .refused("the terminal is not in front") }
        typed.append(draft)
        return .done
    }

    var claudePID: Int32? { nil }
    var claudeVersion: String? { nil }
    func claudeIsRunning() -> Bool { false }
    func claudeIsFrontmost() -> Bool { inFront }
    var accessibilityDisabled: Bool { false }
    func beginShutdown() {}
    var micSnapshot: String { "" }
    func claudeCaptureActive() -> Bool? { nil }
    func otherProcessCapturingInput() -> String? { nil }
    func defaultInputDeviceName() -> String? { nil }
    func startWorkspaceWatch() {}
    var onSessionsChanged: (@MainActor () -> Void)?
    func refreshSessions(watched: Bool) async -> (sessions: [ClaudeSession], recording: Set<String>) { ([], []) }
    func paneFrame(_ s: ClaudeSession) async -> CGRect? { nil }
    func focus(_ s: ClaudeSession, unlessTypedWithin quiet: TimeInterval) async -> BridgeResult { .done }
    func focusComposerIfNeeded(_ s: ClaudeSession) async -> String { "" }
    func micState(_ s: ClaudeSession) async -> MicState { .off }
    func startDictation(_ s: ClaudeSession) async -> BridgeResult { .done }
    func stopDictation(_ s: ClaudeSession) async -> BridgeResult { .done }
    func stopAnyDictation() async -> BridgeResult { .done }
    func draftText(_ s: ClaudeSession) async -> String? { nil }
    func sendDraft(_ s: ClaudeSession, shown: String, stoppedAt: Date, inputAge: @escaping @Sendable () -> Double) async -> BridgeResult { .done }
    func paneDividers(in s: ClaudeSession) async -> [PaneDivider] { [] }
    func focusDivider(_ divider: AnyObject, in s: ClaudeSession) async -> Bool { false }
    func dividerHoldsKeyboard(_ divider: AnyObject) async -> Bool { false }
    func keyboardOnDivider(_ dividers: [AnyObject]) async -> Bool? { nil }
    func chatColumns(in sessions: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)] { [:] }
}

@Suite struct FakeTerminalTests {
    private let s = ClaudeSession(id: "t1", frame: .zero, windowNumber: 0)

    @Test func anInterruptArrivesOnce() async {
        let term = FakeTerminal(inFront: true)
        let adapter: any AgentAdapter = term
        #expect(await adapter.interrupt(s) == .done)
        #expect(term.interrupts == 1)
    }

    @Test func aTypedDraftArrivesAsText() async {
        let term = FakeTerminal(inFront: true)
        let adapter: any AgentAdapter = term
        #expect(await adapter.typeIntoTerminal(s, draft: "run the tests") == .done)
        #expect(term.typed == ["run the tests"])
    }

    @Test func bothRefuseWhenAnotherAppIsInFront() async {
        let term = FakeTerminal(inFront: false)
        let adapter: any AgentAdapter = term
        let refused = BridgeResult.refused("the terminal is not in front")
        #expect(await adapter.interrupt(s) == refused)
        #expect(await adapter.typeIntoTerminal(s, draft: "x") == refused)
        #expect(term.interrupts == 0 && term.typed.isEmpty)
    }
}
