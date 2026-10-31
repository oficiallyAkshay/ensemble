import AppKit
import SwiftUI
import EnsembleCore

struct OverlayBanner: Equatable, Identifiable {
    /// `success`: something was restored or finished (a tick). `info`: a neutral heads-up about what Ensemble is
    /// doing. `refused`: a real problem or a refusal (the amber warning). `sent` and `stopped` are the dictation banners.
    enum Style: Equatable { case sent, stopped, refused, info, success }
    let id = UUID()
    var title: String
    var body: String
    var style: Style = .info
}

/// While dictating, the nose rests on another session: focus moves there when `progress` reaches 1.
struct SessionSwitch: Equatable {
    var name: String?
    var progress: Double
    /// Every open session, left to right as they sit on screen; the island falls back to the plain two-tile
    /// glyph when this is 1 or less.
    var sessionCount: Int = 0
    /// Column indices (1..<sessionCount) where a new screen or window group starts.
    var groupBreaks: Set<Int> = []
    /// Index, into that same left-to-right order, of the session losing and gaining focus.
    var fromIndex: Int = 0
    var toIndex: Int = 0
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var target: CGRect?
    /// What the SwiftUI views draw. Set only when a view needs it (see `OverlayController.update`), so a moving
    /// nose does not re-evaluate the views while the glass dot window does the drawing.
    @Published var nose: CGPoint?
    var hasNose = false
    @Published var listening = false
    @Published var showNoseDot = true
    @Published var gesture: GestureProgress?
    @Published var showHighlight = true
    @Published var banner: OverlayBanner?
    /// The keyboard, mouse or trackpad is in use and no gesture is acting: the highlight fades away until they rest.
    @Published var handsOnInput = false
    /// Live voice level 0...1 while listening (0 when unavailable).
    @Published var audioLevel = 0.0
    /// Show live sound bars instead of the blinking microphone dot.
    @Published var liveSoundBars = false
    /// The name of the session a gesture would act on (the dictating one while dictating).
    @Published var sessionName: String?
    @Published var sessionSwitch: SessionSwitch?
    /// While dictating: what the nose is approaching beyond the dictating session's edge.
    @Published var edge: OverlayEdge?
    /// A send is on its way: the session's name, from the end of the thumbs-up hold until "Sent" or "Not sent".
    @Published var sending: String?
    /// A pane resize is moving the highlighted session: the outline keeps this identity (the key of the frame it had
    /// when the resize began) and springs to each new frame instead of fading out and in. Cleared by the first frame
    /// change after the resize has ended, which fades as usual.
    @Published var glide: String?

    /// One identity per session frame: a new frame is a new outline that fades in, never a moving one.
    static func highlightKey(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }

    var hasContent: Bool {
        (showHighlight && target != nil) || (showNoseDot && hasNose) || listening || banner != nil || sending != nil
    }
}

/// Click-through, non-activating panels (one per screen) that draw the highlight, nose dot, listening
/// border, the island and banners. They never take focus or intercept clicks.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var bannerTask: Task<Void, Never>?
    private var alarmID: UUID?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    func update(target: CGRect?, nose: CGPoint?, lead: DotLead?, listening: Bool, showNoseDot: Bool, showHighlight: Bool) {
        if model.glide != nil, let settled = glideSettled, target != settled {
            model.glide = nil
            glideSettled = nil
        }
        setIfChanged(&model.target, target)
        latestNose = nose
        latestLead = lead
        model.hasNose = nose != nil
        setIfChanged(&model.listening, listening)
        setIfChanged(&model.nose, listening ? nose : nil)
        setIfChanged(&model.showNoseDot, showNoseDot)
        setIfChanged(&model.showHighlight, showHighlight)
        syncPanels()
        syncGlassDot()
    }

    private var latestNose: CGPoint?
    private var latestLead: DotLead?
    /// The frame the highlight had when the last resize ended; nil while one runs or none has.
    private var glideSettled: CGRect??

    /// A pane resize starts (`true`) or has ended (`false`): while it runs, and until the highlighted frame next
    /// changes for another reason, the outline springs to the session's new frame instead of fading to it.
    func glide(_ on: Bool) {
        if on {
            if model.glide == nil, let t = model.target { model.glide = OverlayModel.highlightKey(t) }
            glideSettled = nil
        } else if model.glide != nil {
            glideSettled = .some(model.target)
        }
    }

    /// The refresh rate of the screen the dot is on (where the nose last was, else the main screen). Read once a
    /// second with the camera's rate report, never per frame.
    var dotRefreshRate: Int {
        let screen = latestNose.flatMap { ScreenGeometry.screen(containing: $0) } ?? NSScreen.main
        return screen?.maximumFramesPerSecond ?? 0
    }

    private var glassDotStore: AnyObject?
    /// The dot is its own small window (GlassDot); the SwiftUI overlay never draws it.
    private func syncGlassDot() {
        let dot = (glassDotStore as? GlassDot) ?? GlassDot()
        glassDotStore = dot
        let visible = !model.listening && (model.showNoseDot || model.gesture != nil)
        dot.show(at: visible ? latestNose : nil, lead: model.gesture == nil ? latestLead : nil, dimmed: model.handsOnInput && model.gesture == nil)
        dot.setScrolling(scrolling)
    }

    /// Re-applies visibility toggles between coordinator updates.
    func setGesture(_ g: GestureProgress?) {
        setIfChanged(&model.gesture, g)
        syncGlassDot()
    }

    func setVisibility(showNoseDot: Bool, showHighlight: Bool) {
        setIfChanged(&model.showNoseDot, showNoseDot)
        setIfChanged(&model.showHighlight, showHighlight)
        syncPanels()
        syncGlassDot()
    }

    func setSession(name: String?, switching: SessionSwitch?) {
        setIfChanged(&model.sessionName, name)
        setIfChanged(&model.sessionSwitch, switching)
    }

    func setEdge(_ edge: OverlayEdge?) { setIfChanged(&model.edge, edge) }

    func setSending(name: String?) {
        setIfChanged(&model.sending, name)
        syncPanels()
    }

    func setLiveSoundBars(_ on: Bool) { setIfChanged(&model.liveSoundBars, on) }

    func setAudioLevel(_ v: Double) {
        model.audioLevel = v
    }

    func setHandsOnInput(_ on: Bool) {
        guard model.handsOnInput != on else { return }
        model.handsOnInput = on
        syncGlassDot()
    }

    func setScrolling(_ on: Bool) {
        guard scrolling != on else { return }
        scrolling = on
        syncGlassDot()
    }
    private var scrolling = false

    func showBanner(title: String, body: String, style: OverlayBanner.Style = .info, seconds: Double = 5) {
        guard alarmID == nil else { return }   // an open safety alarm is never covered by a passing message
        let banner = OverlayBanner(title: title, body: body, style: style)
        model.banner = banner
        syncPanels()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.model.banner?.id == banner.id else { return }
            self.model.banner = nil
            self.syncPanels()
        }
    }

    /// The safety alarm (Claude's microphone may still be on). Stays on screen until `resolveAlarm`, whatever the
    /// system's notification permission or Focus setting does with the notification that goes with it.
    func showAlarm(title: String, body: String) {
        let banner = OverlayBanner(title: title, body: body, style: .refused)
        alarmID = banner.id
        bannerTask?.cancel()
        model.banner = banner
        syncPanels()
    }

    func resolveAlarm() {
        guard let id = alarmID else { return }
        alarmID = nil
        if model.banner?.id == id { model.banner = nil }
        syncPanels()
    }

    /// A new action starts: an older message must not reappear once that action's own feedback ends.
    func clearBanner() {
        guard alarmID == nil else { return }
        bannerTask?.cancel()
        guard model.banner != nil else { return }
        model.banner = nil
        syncPanels()
    }

    private func setIfChanged<T: Equatable>(_ slot: inout T, _ value: T) {
        if slot != value { slot = value }
    }

    private var hideTask: Task<Void, Never>?

    /// Panels leave the screen only after the last fade has played out, so nothing is cut off mid-animation.
    private func syncPanels() {
        if model.hasContent {
            hideTask?.cancel(); hideTask = nil
            if panels.isEmpty { rebuildPanels() }
            for panel in panels.values where !panel.isVisible { panel.orderFrontRegardless() }
        } else if hideTask == nil, panels.values.contains(where: \.isVisible) {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, let self else { return }
                self.hideTask = nil
                guard !self.model.hasContent else { return }
                for panel in self.panels.values where panel.isVisible { panel.orderOut(nil) }
            }
        }
    }

    private func rebuildPanels() {
        for panel in panels.values { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        guard model.hasContent else { return }
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = ScreenGeometry.displayID(of: screen) else { continue }
            let panel = OverlayPanel(screen: screen)
            let notchHeight = screen.safeAreaInsets.top
            let notchWidth = notchHeight > 0 ? max(0, screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)) : 0
            let root = OverlayScreenView(model: model, screenFrame: ScreenGeometry.topLeftFrame(of: screen), isPrimary: index == 0,
                                         notch: CGSize(width: notchWidth, height: notchHeight))
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.orderFrontRegardless()
            panels[id] = panel
        }
    }
}

private final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
