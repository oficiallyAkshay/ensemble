import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A stand-in adapter: the coordinator only ever holds `any AgentAdapter`, so whatever drives it must satisfy the
/// protocol with nothing but the plain types in EnsembleCore.
private final class StubAdapter: AgentAdapter, @unchecked Sendable {
    var claudePID: pid_t? { 42 }
    var claudeVersion: String? { nil }
    func claudeIsRunning() -> Bool { true }
    func claudeIsFrontmost() -> Bool { false }
    var accessibilityDisabled: Bool { false }
    func beginShutdown() {}
    var micSnapshot: String { "mic not read yet" }
    func claudeCaptureActive() -> Bool? { nil }
    func otherProcessCapturingInput() -> String? { nil }
    func defaultInputDeviceName() -> String? { nil }
    func startWorkspaceWatch() {}
    var onSessionsChanged: (@MainActor () -> Void)?
    let session = ClaudeSession(id: "w1#0", frame: CGRect(x: 0, y: 0, width: 400, height: 300), windowNumber: 1)
    let divider = PaneDivider(element: NSObject(), frame: CGRect(x: 400, y: 0, width: 4, height: 300), minPercent: 20)
    func refreshSessions(watched: Bool) async -> (sessions: [ClaudeSession], recording: Set<String>) { ([session], []) }
    func paneFrame(_ s: ClaudeSession) async -> CGRect? { s.frame }
    func focus(_ s: ClaudeSession, unlessTypedWithin quiet: TimeInterval) async -> BridgeResult { .done }
    func focusComposerIfNeeded(_ s: ClaudeSession) async -> String { "focused" }
    func micState(_ s: ClaudeSession) async -> MicState { .off }
    func startDictation(_ s: ClaudeSession) async -> BridgeResult { .done }
    func stopDictation(_ s: ClaudeSession) async -> BridgeResult { .done }
    func stopAnyDictation() async -> BridgeResult { .done }
    func draftText(_ s: ClaudeSession) async -> String? { "hello" }
    func sendDraft(_ s: ClaudeSession, shown: String, stoppedAt: Date, inputAge: @escaping @Sendable () -> Double) async -> BridgeResult {
        .refused("typed \(inputAge())")
    }
    func paneDividers(in s: ClaudeSession) async -> [PaneDivider] { [divider] }
    func focusDivider(_ divider: AnyObject, in s: ClaudeSession) async -> Bool { divider === self.divider.element }
    func dividerHoldsKeyboard(_ divider: AnyObject) async -> Bool { false }
    func keyboardOnDivider(_ dividers: [AnyObject]) async -> Bool? { dividers.isEmpty ? nil : true }
    func chatColumns(in sessions: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, (transcript: $0.frame, column: nil)) })
    }
}

@Suite("AgentAdapter") struct AgentAdapterTests {
    @Test func sessionsAndTheirStateAreReadThroughTheProtocol() async {
        let adapter: any AgentAdapter = StubAdapter()
        let scan = await adapter.refreshSessions(watched: false)
        #expect(scan.sessions.map(\.id) == ["w1#0"])
        #expect(await adapter.micState(scan.sessions[0]) == .off)
        #expect(await adapter.draftText(scan.sessions[0]) == "hello")
        #expect(await adapter.chatColumns(in: scan.sessions)["w1#0"]?.transcript == scan.sessions[0].frame)
    }

    @Test func aSendIsAnsweredWithTheInputAgeItWasGiven() async {
        let adapter: any AgentAdapter = StubAdapter()
        let s = await adapter.refreshSessions(watched: false).sessions[0]
        let result = await adapter.sendDraft(s, shown: "hello", stoppedAt: Date(), inputAge: { 3 })
        #expect(result == .refused("typed 3.0"))
    }

    @Test func aDividerIsHandedBackAsTheSameReference() async {
        let adapter = StubAdapter()
        let s = adapter.session
        let found = await adapter.paneDividers(in: s)
        #expect(found.count == 1 && found[0].minPercent == 20)
        #expect(await adapter.focusDivider(found[0].element, in: s))
        #expect(await adapter.focusDivider(NSObject(), in: s) == false)
        #expect(await adapter.keyboardOnDivider(found.map(\.element)) == true)
        #expect(await adapter.keyboardOnDivider([]) == nil)
    }
}
