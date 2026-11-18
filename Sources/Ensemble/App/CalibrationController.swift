import AppKit
import QuartzCore
import SwiftUI
import EnsembleCore

/// A screen as the intro lists it.
struct CalibrationScreenInfo: Identifiable {
    let id: Int
    let name: String
    let detail: String
    /// Position in the calibration order (1-based), or nil when this screen keeps the calibration it has.
    let order: Int?
}

@MainActor
final class CalibrationModel: ObservableObject {
    enum Phase: Equatable { case intro, steps }

    @Published var phase = Phase.intro
    @Published var screens: [CalibrationScreenInfo] = []
    @Published var introHeadline = ""
    /// Which saved position this run replaces or adds, when there is more than one; nil otherwise.
    @Published var note: String?
    /// What the camera path is waiting for ("Starting the camera..."); empty once a face has been read.
    @Published var waiting = ""
    @Published var activeScreen = -1          // index into `screens` of the screen showing its dot
    @Published var finishedScreens = 0
    @Published var dot = CGPoint(x: 0, y: 0)
    @Published var dotVisible = false
    @Published var sampling = 0.0          // 0...1 progress of the ring
    @Published var headline = ""
    @Published var detail = ""
    @Published var step = ""
    @Published var faceMissing = false
    /// True when a point has not been captured for too long: Skip this point / Retry are shown.
    @Published var offerChoice = false
    var onSkip: () -> Void = {}
    var onRetry: () -> Void = {}
}

/// One screen's calibration: its stable id and the frame it had, with the samples taken on it.
struct ScreenCalibrationResult {
    let screenID: String
    let frame: CGRect
    let samples: [CalibrationSample]
}

/// Where the camera path stands, for the calibration window to show while it waits for a first face reading.
struct CalibrationFeed {
    var head: () -> HeadObservation?
    /// "Starting the camera...", "Loading face tracking...", "Looking for your face...".
    var waitingFor: () -> String = { "Looking for your face\u{2026}" }
    /// Set when the camera or the face tracker has failed for good; the window closes with that reason.
    var failure: () -> String? = { nil }
}

/// Full-screen calibration. The window is up on every screen the moment `run` is called, naming the screens it found;
/// a dot then visits five spots per screen, and each is captured only when the head has turned toward it and holds
/// still (`AimGate`). Esc cancels. The completion is called exactly once; an empty array means cancelled or failed
/// (`failure` says why when it failed).
@MainActor
final class CalibrationController {
    static let shared = CalibrationController()

    private let introSeconds = 2.5
    private let cameraWaitSeconds = 30.0

    private let model = CalibrationModel()
    private var windows: [CalibrationWindow] = []
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var completion: (([ScreenCalibrationResult]) -> Void)?
    private var returnPressed = false
    private var choice: Choice?
    private enum Choice { case skip, retry }

    /// Why the last run ended without results, when it was not the owner's Esc.
    private(set) var failure: String?
    var isRunning: Bool { task != nil }

    /// Visits every screen in `screens` (every connected screen by default); pass a subset to calibrate
    /// only those (a newly connected display, say) while the others keep their own calibration.
    /// `clickedAt` (`CACurrentMediaTime`) lets the log say how long the window and the first face reading took.
    /// `note` is a line for the intro naming the position this run is for.
    /// `firstDotFrom` is a screen already calibrated and its centre sample: a screen with no earlier screen in this run
    /// needs a turn away from it for its first dot, not only stillness.
    func run(screens: [NSScreen] = NSScreen.screens, note: String? = nil, firstDotFrom: (frame: CGRect, centre: CalibrationSample)? = nil,
             feed: CalibrationFeed, clickedAt: TimeInterval = CACurrentMediaTime(),
             completion: @escaping ([ScreenCalibrationResult]) -> Void) {
        guard task == nil, !screens.isEmpty else { completion([]); return }
        self.completion = completion
        failure = nil
        returnPressed = false
        choice = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil
            case 36, 76: self.returnPressed = true; return nil
            default: return event
            }
        }
        model.onSkip = { [weak self] in self?.choice = .skip }
        model.onRetry = { [weak self] in self?.choice = .retry }
        prepareModel(screens: screens)
        model.note = note
        presentAll(screens: screens)
        let visits = screens.map { s -> String in
            let f = ScreenGeometry.topLeftFrame(of: s)
            return "\(ScreenGeometry.stableID(of: s) ?? "?")@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
        }
        EnsembleLog.write(String(format: "calibration window up %.0f ms after the click (%d screens)", (CACurrentMediaTime() - clickedAt) * 1000, screens.count)
                          + ": \(visits), first dot \(firstDotFrom == nil ? "on stillness" : "needs a turn from a calibrated screen")")
        task = Task { [weak self] in
            guard let self else { return }
            let results = await self.collect(screens: screens, firstDotFrom: firstDotFrom, feed: feed, clickedAt: clickedAt)
            self.finish(results)
        }
    }

    func cancel() {
        task?.cancel()
        finish([])
    }

    private func finish(_ results: [ScreenCalibrationResult]) {
        guard let done = completion else { return }
        completion = nil
        task?.cancel()
        task = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = windows
        windows = []
        // Fade, never cut: the windows ease out while the app moves on.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            for window in closing { window.animator().alphaValue = 0 }
        }, completionHandler: {
            for window in closing { window.orderOut(nil); window.close() }
        })
        model.dotVisible = false
        done(results)
    }

    // MARK: - Flow

    private func prepareModel(screens: [NSScreen]) {
        let all = NSScreen.screens
        let descriptions = all.enumerated().map { ScreenDescription(name: $0.element.localizedName, frame: ScreenGeometry.topLeftFrame(of: $0.element), isMain: $0.offset == 0) }
        model.screens = all.enumerated().map { index, screen in
            let order = screens.firstIndex(of: screen).map { $0 + 1 }
            return CalibrationScreenInfo(id: index, name: screen.localizedName,
                                         detail: ScreenLayout.detail(of: descriptions[index], among: descriptions), order: order)
        }
        model.introHeadline = ScreenLayout.headline(count: all.count)
        model.phase = .intro
        model.waiting = "Starting the camera\u{2026}"
        model.activeScreen = -1
        model.finishedScreens = 0
        model.dotVisible = false
        model.offerChoice = false
        model.faceMissing = false
    }

    private func collect(screens: [NSScreen], firstDotFrom: (frame: CGRect, centre: CalibrationSample)?, feed: CalibrationFeed,
                         clickedAt: TimeInterval) async -> [ScreenCalibrationResult] {
        // The intro shows at once and the camera path catches up behind it; the first dot waits for a face reading.
        let introStart = CACurrentMediaTime()
        var sawFace = false
        while true {
            if Task.isCancelled { return [] }
            let now = CACurrentMediaTime()
            if let head = feed.head(), head.faceCount == 1, now - head.t < 1.0 {
                if !sawFace {
                    sawFace = true
                    EnsembleLog.write(String(format: "calibration first face reading %.0f ms after the click", (now - clickedAt) * 1000))
                }
                model.waiting = ""
            } else {
                sawFace = false
                model.waiting = feed.waitingFor()
            }
            if let why = feed.failure() { failure = why; return [] }
            if now - introStart > cameraWaitSeconds { failure = "The camera did not start: no face reading within \(Int(cameraWaitSeconds)) s"; return [] }
            let introDone = now - introStart >= introSeconds || returnPressed
            if introDone, sawFace { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        var results: [ScreenCalibrationResult] = []
        var dropped: [String] = []
        for (index, screen) in screens.enumerated() {
            let frame = ScreenGeometry.topLeftFrame(of: screen)
            guard let screenID = ScreenGeometry.stableID(of: screen) else { return [] }
            let infoIndex = model.screens.firstIndex { $0.order == index + 1 } ?? 0
            model.phase = .steps
            model.activeScreen = infoIndex
            model.finishedScreens = index
            model.dotVisible = false
            model.step = ScreenLayout.stepTitle(index: index, count: screens.count, name: screen.localizedName, facing: index > 0)

            let spots = CalibrationTargets.points(in: frame, topReserve: Self.topReserve(of: screen))
            var samples: [CalibrationSample] = []
            let previousScreen = results.last.flatMap { last in last.samples.first.map { (frame: last.frame, centre: $0) } } ?? firstDotFrom
            for (spotIndex, spot) in spots.enumerated() {
                model.dot = CGPoint(x: spot.x - frame.minX, y: spot.y - frame.minY)
                model.dotVisible = true
                model.sampling = 0
                model.faceMissing = false
                model.offerChoice = false
                let rule = AimRule()
                let requirement: AimRequirement
                if spotIndex == 0 { requirement = rule.requirement(forFirstDotOn: frame, previousScreen: previousScreen) }
                else { requirement = rule.requirement(forTarget: spot, on: frame, accepted: samples) }

                switch await capture(rule: rule, requirement: requirement, feed: feed, spot: spot, number: spotIndex + 1, of: spots.count) {
                case .cancelled: return []
                case .skipped: dropped.append(screen.localizedName)
                case .sample(let s): samples.append(s)
                }
            }
            // The pointer fit needs all five points on a screen; a screen with a skipped point stays uncalibrated.
            if samples.count == spots.count {
                results.append(ScreenCalibrationResult(screenID: screenID, frame: frame, samples: samples))
            }
        }
        if !dropped.isEmpty {
            failure = "A point was skipped, so \(Set(dropped).sorted().joined(separator: " and ")) is not calibrated"
        }
        return results
    }

    private enum Capture {
        case cancelled
        case skipped
        case sample(CalibrationSample)
    }

    private func capture(rule: AimRule, requirement: AimRequirement, feed: CalibrationFeed, spot: CGPoint, number: Int, of total: Int) async -> Capture {
        var gate = AimGate(rule: rule, requirement: requirement, startedAt: CACurrentMediaTime())
        // Head positions over the last moments, averaged into the sample when it is captured (where you sat).
        var positions: [(t: TimeInterval, p: HeadPosition?)] = []
        var lastT: TimeInterval = -1
        let pointLine = "Point \(number) of \(total)"
        var loggedMovement = false
        choice = nil
        while true {
            if Task.isCancelled { return .cancelled }
            let now = CACurrentMediaTime()
            if let head = feed.head(), head.faceCount == 1, head.t != lastT {
                lastT = head.t
                gate.push(AimReading(t: head.t, yaw: head.yaw, pitch: head.pitch))
                positions.append((head.t, head.position))
                positions.removeAll { $0.t < head.t - 1.0 }
            }
            let faceLost = now - lastT > 1.0
            model.faceMissing = faceLost
            switch gate.update(now: now) {
            case .waiting(let hint):
                model.sampling = 0
                model.offerChoice = false
                model.headline = hint == .turnToDot ? "Turn your nose to the dot" : "Move your head, not just your eyes"
                model.detail = faceLost ? "I cannot see your face. Look at the camera." : pointLine
            case .filling(let progress):
                model.sampling = progress
                model.headline = "Hold still"
                model.detail = pointLine
            case .captured(let yaw, let pitch):
                model.sampling = 1
                EnsembleLog.write(String(format: "calibration point %d of %d captured (yaw %.3f, pitch %.3f)", number, total, yaw, pitch))
                let recent = positions.filter { $0.t >= lastT - 0.4 }
                // Only when every recent reading had one: a sample with a partly missing position is not trusted.
                let known = recent.compactMap(\.p)
                let position = !known.isEmpty && known.count == recent.count ? Self.mean(of: known) : nil
                return .sample(CalibrationSample(yaw: yaw, pitch: pitch, target: spot, position: position))
            case .timedOut:
                if !loggedMovement {
                    loggedMovement = true
                    EnsembleLog.write("calibration point \(number) of \(total) not reached after \(Int(rule.giveUpAfter)) s: \(String(describing: requirement))")
                }
                model.sampling = 0
                model.offerChoice = true
                model.headline = "I did not see your head turn to the dot"
                model.detail = "Skipping leaves this screen uncalibrated."
                switch choice {
                case .skip?: choice = nil; model.offerChoice = false; return .skipped
                case .retry?: choice = nil; model.offerChoice = false; loggedMovement = false; gate.restart(at: now)
                case nil: break
                }
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private static func mean(of ps: [HeadPosition]) -> HeadPosition {
        let n = Double(ps.count)
        return HeadPosition(x: ps.map(\.x).reduce(0, +) / n, y: ps.map(\.y).reduce(0, +) / n, z: ps.map(\.z).reduce(0, +) / n)
    }

    /// The top band a dot must clear: the menu bar (hidden under the calibration window, but where a top session's
    /// edge sits) or the notch's safe area, whichever is taller.
    private static func topReserve(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 0)
    }

    /// One window per connected screen, all up at once and fading in; the first is key so Esc reaches it.
    private func presentAll(screens: [NSScreen]) {
        let all = NSScreen.screens
        windows = all.enumerated().map { index, screen in
            let window = CalibrationWindow(screen: screen) { [weak self] in self?.cancel() }
            let host = NSHostingView(rootView: CalibrationView(model: model, index: index, size: screen.frame.size))
            host.sizingOptions = []
            window.contentView = host
            window.alphaValue = 0
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
        for (i, window) in windows.enumerated() {
            if i == 0 { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            for window in windows { window.animator().alphaValue = 1 }
        }
    }
}

/// A plain borderless window cannot become key, so it never receives Esc; this one can.
private final class CalibrationWindow: NSWindow {
    private let onEscape: () -> Void

    init(screen: NSScreen, onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.94)
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

private struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel
    let index: Int
    let size: CGSize

    private var info: CalibrationScreenInfo? { model.screens.first { $0.id == index } }
    private var isActive: Bool { model.phase == .steps && model.activeScreen == index }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if model.phase == .intro {
                    intro
                } else if isActive {
                    active
                } else {
                    idle
                }
            }
            .frame(width: size.width, height: size.height * 0.5, alignment: .center)
            .offset(y: size.height * 0.18)
            .transition(.opacity)

            if isActive, model.dotVisible {
                TargetDot(progress: model.sampling)
                    .position(model.dot)
                    .animation(.smooth(duration: 0.5), value: model.dot)
                    .transition(.opacity)
            }

            Text("Press Esc to cancel")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: size.width)
                .offset(y: size.height - 56)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.35), value: model.phase)
        .animation(.smooth(duration: 0.35), value: model.activeScreen)
        .animation(.smooth(duration: 0.35), value: model.headline)
        .animation(.smooth(duration: 0.35), value: model.waiting)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Text(model.introHeadline).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            if let note = model.note {
                Text(note).font(.title3).foregroundStyle(.white.opacity(0.8))
            }
            VStack(spacing: 6) {
                ForEach(model.screens) { screen in
                    let here = screen.id == index
                    VStack(spacing: 1) {
                        Text("\(screen.name)\(here ? "  (this screen)" : "")")
                            .font(.title3.weight(here ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(here ? 1 : 0.7))
                        Text("\(screen.detail)\(screen.order.map { ", calibrated number \($0)" } ?? ", keeps its calibration")")
                            .font(.callout).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Text(model.waiting.isEmpty ? "Starting in a moment. Press Return to start now." : model.waiting)
                .font(.callout).foregroundStyle(.white.opacity(0.5)).padding(.top, 6)
        }
        .multilineTextAlignment(.center)
    }

    private var active: some View {
        VStack(spacing: 10) {
            if !model.step.isEmpty {
                Text(model.step).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.5))
            }
            Text(model.headline).font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(model.detail)
                .font(.title3)
                .foregroundStyle(model.faceMissing ? Color.orange : Color.white.opacity(0.65))
            if model.offerChoice {
                HStack(spacing: 12) {
                    Button("Skip this point") { model.onSkip() }.ensembleButtonStyle()
                    Button("Retry") { model.onRetry() }.ensembleButtonStyle(prominent: true)
                }
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var idle: some View {
        VStack(spacing: 8) {
            if let info {
                Text(info.name).font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Text(info.order.map { $0 <= model.finishedScreens ? "Done" : "Up next: screen \($0)" } ?? "Keeps its calibration")
                    .font(.title3).foregroundStyle(.white.opacity(0.5))
            }
        }
        .multilineTextAlignment(.center)
    }
}

private struct TargetDot: View {
    let progress: Double
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: breathe ? 84 : 64, height: breathe ? 84 : 64)
            Circle().stroke(.white.opacity(0.25), lineWidth: 4).frame(width: 58, height: 58)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(-90))
            Circle().fill(.white).frame(width: 22, height: 22).shadow(color: Color.accentColor, radius: 10)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true } }
    }
}
