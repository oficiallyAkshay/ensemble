import AVFoundation
import EnsembleCore
import Foundation
import os
import QuartzCore

enum EngineStatus: Equatable {
    case stopped, starting
    case running(fps: Int, camera: String, cameraID: String)
    case noCamera, permissionDenied
    case error(String)
    case faceTrackerReady
    case faceTrackerRestarting
    case faceTrackerFailed(String)
}

/// Camera in, observations out: hand pose, head angles and frame brightness for every frame.
/// All callbacks run on the main actor.
@MainActor
final class VisionEngine {
    var onHand: ((HandObservation) -> Void)?
    var onHead: ((HeadObservation) -> Void)?
    var onLight: ((FrameLight) -> Void)?
    var onStatus: ((EngineStatus) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private(set) var isRunning = false
    private var trackerRetry = TrackerRetry()
    private var pendingTrackerRetry: Task<Void, Never>?

    private let camera = CameraSession()
    private let face = FaceTracker()
    private let analyzer = FrameAnalyzer()
    /// Hand pose runs here, never on the camera queue. On the camera queue it held the queue for its whole run, and
    /// with late frames discarded (`CameraSession`) every frame that arrived meanwhile was dropped: fewer head
    /// readings than the camera's 30 a second, and a dot that stepped unevenly.
    private let handQueue = DispatchQueue(label: "ensemble.hand", qos: .userInitiated)
    /// One hand frame at a time: a frame that arrives while one is analysed skips hand pose (face and light still run).
    private let handBusy = OSAllocatedUnfairLock(initialState: false)
    /// The latest hand result, for the planner, which only the camera queue touches; taken at the next frame.
    private let handNote = OSAllocatedUnfairLock<(present: Bool, t: TimeInterval)?>(initialState: nil)
    /// Owned by the camera queue. Decides which analyses run on each frame.
    nonisolated(unsafe) private var planner = FrameRatePlanner()
    private struct RateHints { var forceFull = false; var lastFaceSeenAt: TimeInterval? }
    private let hints = OSAllocatedUnfairLock(initialState: RateHints())
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var cameraLabel = ""
    nonisolated(unsafe) private var cameraID = ""
    nonisolated(unsafe) private var fpsWindowStart = 0.0
    nonisolated(unsafe) private var fpsFrames = 0
    nonisolated(unsafe) private var lastFrameAt = 0.0
    private var cameraStarted = false
    private var requestedCamera: String?
    private var watchdog: Timer?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private static let noFrameLimit = 3.0

    init() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceConnected() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.deviceDisconnected(id) }
        }
        face.onReady = { [weak self] delegate in
            self?.onDiagnostic?("face tracker ready (\(delegate))")
            self?.onStatus?(.faceTrackerReady)
        }
        face.onFailure = { [weak self] message in self?.trackerFailed(message) }
        face.onHead = { [weak self] head in
            guard let self else { return }
            self.trackerRetry.reset()
            if head.faceCount >= 1 { self.hints.withLock { $0.lastFaceSeenAt = CACurrentMediaTime() } }
            self.onHead?(head)
        }
        face.onDiagnostic = { [weak self] note in self?.onDiagnostic?(note) }
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
        camera.onNote = { [weak self] note in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onDiagnostic?(note) } }
        }
        camera.onInterrupted = { [weak self] message, token in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(message, token: token) } }
        }
    }

    private func trackerFailed(_ message: String) {
        guard isRunning else { return }
        let delay = trackerRetry.nextDelay()
        onDiagnostic?("face tracker failed (\(message)); retry \(trackerRetry.failures) in \(Int(delay)) s")
        guard delay > 0 else { return restartTracker() }
        // The failure stays on the status during the wait, so the panel says why there is no pointer.
        onStatus?(.faceTrackerFailed(message))
        let mine = generation
        pendingTrackerRetry?.cancel()
        pendingTrackerRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // A stop or a camera start since (which starts the tracker itself) changes the generation.
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.restartTracker()
        }
    }

    private func restartTracker() {
        onStatus?(.faceTrackerRestarting)
        face.start()
    }

    /// True while something needs every hand frame (dictating, a send pending, calibrating, a gesture held).
    func setForceFullRate(_ on: Bool) { hints.withLock { if $0.forceFull != on { $0.forceFull = on } } }

    /// A camera (re)appeared. In automatic mode, a camera the owner would now be picked over the one running
    /// (an external camera just plugged in, say) restarts the session onto it.
    private func deviceConnected() {
        guard isRunning, requestedCamera == nil, let preferred = CameraSession.pick(named: nil), preferred.uniqueID != cameraID else { return }
        onDiagnostic?("a camera connected; switching to \(preferred.localizedName)")
        start(cameraName: nil)
    }

    /// The camera in use was unplugged: restart so the session moves to whatever camera is left, and the
    /// setup logic sees the camera it now actually uses.
    private func deviceDisconnected(_ id: String?) {
        guard isRunning, requestedCamera == nil, let id, id == cameraID else { return }
        onDiagnostic?("the camera in use disconnected; picking another")
        start(cameraName: nil)
    }

    static func cameraNames() -> [String] { CameraSession.names() }

    /// Starts the camera and the face tracker. Calling it while running restarts with the new camera. A camera
    /// restart (wake, a replugged or switched camera, the watchdog) keeps the face tracker page: reloading it
    /// unpacks the model again and leaves a second or two with no head readings.
    func start(cameraName: String?) {
        if isRunning { halt(keepTracker: true) }
        isRunning = true
        cameraStarted = false
        requestedCamera = cameraName
        trackerRetry.reset()
        generation += 1
        fpsWindowStart = 0
        fpsFrames = 0
        let mine = generation
        onStatus?(.starting)
        if face.isReady {
            onStatus?(.faceTrackerReady)
        } else if !face.isStarted {
            face.start()
        }
        Task { @MainActor in
            do {
                let identity = try await camera.start(named: cameraName, token: mine)
                guard mine == generation, isRunning else { camera.stop(token: mine); return }
                cameraLabel = identity.name
                cameraID = identity.id
                lastFrameAt = CACurrentMediaTime()
                cameraStarted = true
                startWatchdog()
                onStatus?(.running(fps: 0, camera: identity.name, cameraID: identity.id))
            } catch {
                guard mine == generation else { return }
                halt()
                switch error as? CameraError {
                case .permissionDenied: onStatus?(.permissionDenied)
                case .noCamera: onStatus?(.noCamera)
                case .failed(let message): onStatus?(.error(message))
                case nil: onStatus?(.error(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        halt()
        onStatus?(.stopped)
    }

    /// A report from a replaced session (the camera in use was unplugged and the engine already restarted on
    /// another) carries an older token and must not stop the new run.
    private func fail(_ message: String, token: Int) {
        guard isRunning, token == generation else { return }
        halt()
        onStatus?(.error(message))
    }

    /// A camera that stops delivering frames (sleep, an interruption, a USB hiccup) is restarted after 3 s.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkFrames() {
        guard isRunning, cameraStarted else { return }
        let silent = CACurrentMediaTime() - lastFrameAt
        guard silent > Self.noFrameLimit else { return }
        onDiagnostic?("no camera frames for \(Int(silent)) s; restarting the camera")
        start(cameraName: requestedCamera)
    }

    private func halt(keepTracker: Bool = false) {
        isRunning = false
        cameraStarted = false
        watchdog?.invalidate()
        watchdog = nil
        generation += 1
        camera.stop()
        if !keepTracker { face.stop() }
    }

    // MARK: Camera queue

    nonisolated private func process(_ buffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let t = CACurrentMediaTime()
        lastFrameAt = t
        let mine = generation

        if let note = handNote.withLock({ n -> (present: Bool, t: TimeInterval)? in defer { n = nil }; return n }) {
            planner.noteHand(present: note.present, at: note.t)
        }
        let hint = hints.withLock { $0 }
        let plan = planner.plan(now: t, forceFull: hint.forceFull, lastFaceSeenAt: hint.lastFaceSeenAt)

        // The face frame goes out first: the nose dot waits on the face tracker.
        if plan.runFace, face.gate.tryEnter(now: t) {
            if let jpeg = analyzer.jpeg(from: pixels) {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning, self.generation == mine else { self?.face.gate.leave(); return }
                        self.face.submit(jpeg: jpeg, t: t)
                    }
                }
            } else {
                face.gate.leave()
            }
        }

        if plan.runHand { analyzeHand(buffer, at: t, generation: mine) }
        let light = plan.runLight ? analyzer.light(from: pixels, at: t) : nil

        if fpsWindowStart == 0 { fpsWindowStart = t }
        fpsFrames += 1
        var fps: Int?
        if t - fpsWindowStart >= 1 {
            fps = Int((Double(fpsFrames) / (t - fpsWindowStart)).rounded())
            fpsWindowStart = t
            fpsFrames = 0
        }
        let label = cameraLabel
        let id = cameraID
        if light == nil, fps == nil { return }

        // Captured by value: older Swift compilers (6.0, 6.1) reject a captured `var` in this concurrently-executing closure.
        DispatchQueue.main.async { [weak self, light, fps] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == mine else { return }
                if let light { self.onLight?(light) }
                if let fps { self.onStatus?(.running(fps: fps, camera: label, cameraID: id)) }
            }
        }
    }

    /// Hand pose for one frame on its own queue, latest frame only: while one runs, others skip it. The result
    /// reaches the main actor only if the run that sent the frame is still the current one.
    nonisolated private func analyzeHand(_ buffer: CMSampleBuffer, at t: TimeInterval, generation mine: Int) {
        let free = handBusy.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard free else {
            EnsembleTrace.write(t, "hand frame skipped: the previous one is still being analysed")
            return
        }
        let frame = HandFrame(buffer: buffer)
        handQueue.async { [weak self] in
            guard let self else { return }
            let started = CACurrentMediaTime()
            let hand = self.analyzer.hand(from: frame.buffer, at: t)
            self.handNote.withLock { $0 = (hand.present, t) }
            self.handBusy.withLock { $0 = false }
            EnsembleTrace.write(t, "hand pose took \(Int(((CACurrentMediaTime() - started) * 1000).rounded())) ms")
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == mine else { return }
                    self.onHand?(hand)
                }
            }
        }
    }
}

/// A camera frame handed to the hand queue. The capture output never writes to a delivered buffer, and after the
/// hand-off only the hand queue reads it, so sharing it is safe though `CMSampleBuffer` is not marked `Sendable`.
private struct HandFrame: @unchecked Sendable { let buffer: CMSampleBuffer }
