import AVFoundation
import EnsembleCore
import Foundation

enum CameraError: Error, Equatable {
    case permissionDenied
    case noCamera
    case failed(String)
}

/// Owns the AVCaptureSession. Frames arrive on `queue`; everything else is serialized on it too.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ensemble.camera", qos: .userInitiated)
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// The message and the token of the start whose session reported it, so a late report from a replaced
    /// session can be told apart from one about the current run.
    var onInterrupted: ((String, Int) -> Void)?
    var onNote: ((String) -> Void)?

    private var session: AVCaptureSession?
    /// Token of the start that owns `session`. Queue-confined.
    private var activeToken = 0
    private var observers: [NSObjectProtocol] = []

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices
    }

    static func names() -> [String] { devices().map(\.localizedName) }

    /// By name when given and present; otherwise `CameraChoices.automaticPick`.
    static func pick(named name: String?, calibratedIDs: Set<String>) -> AVCaptureDevice? {
        let all = devices()
        if let name, let match = all.first(where: { $0.localizedName == name }) { return match }
        let kinds = all.map { device -> (id: String, kind: CameraKind) in
            (device.uniqueID, device.deviceType == .external ? .external : device.deviceType == .builtInWideAngleCamera ? .builtIn : .other)
        }
        return CameraChoices.automaticPick(kinds, calibratedIDs: calibratedIDs).map { all[$0] }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Builds and starts the session on the camera queue. Returns the camera's name and its stable unique id
    /// (used to tell cameras apart across reconnects, where the name alone is ambiguous for identical models).
    func start(named name: String?, calibratedIDs: Set<String>, token: Int) async throws -> (name: String, id: String) {
        guard await Self.requestAccess() else { throw CameraError.permissionDenied }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.startOnQueue(named: name, calibratedIDs: calibratedIDs, token: token)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startOnQueue(named name: String?, calibratedIDs: Set<String>, token: Int) throws -> (name: String, id: String) {
        teardownOnQueue()
        activeToken = token
        guard let device = Self.pick(named: name, calibratedIDs: calibratedIDs) else { throw CameraError.noCamera }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .high

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.failed(error.localizedDescription) }
        guard session.canAddInput(input) else { throw CameraError.failed("Cannot use camera \(device.localizedName)") }
        session.addInput(input)
        // Held until the session runs: a session that starts with the device unlocked puts its own format back.
        let locked = lockFormat(of: device)
        defer { if locked { device.unlockForConfiguration() } }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.failed("Cannot read frames from \(device.localizedName)") }
        session.addOutput(output)
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.onInterrupted?(error?.localizedDescription ?? "Camera error", token)
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.onInterrupted?("\(device.localizedName) was disconnected", token)
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.onNote?("camera interrupted; frames pause until it ends")
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.onNote?("camera interruption ended")
            },
        ]

        self.session = session
        session.startRunning()
        guard session.isRunning else {
            teardownOnQueue()
            throw CameraError.failed("Camera \(device.localizedName) did not start")
        }
        return (device.localizedName, device.uniqueID)
    }

    /// Center Stage crops and pans the picture to follow the face, which moves the head in the frame without the
    /// head moving and breaks the calibration. Off for Ensemble's own capture; the user can still change it in
    /// Control Center (cooperative mode).
    private static func turnOffCenterStage() {
        guard AVCaptureDevice.isCenterStageEnabled || AVCaptureDevice.centerStageControlMode != .cooperative else { return }
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = false
    }

    /// Locks the device to the best format for the trackers at 30 fps (CameraFormatChoice). Returns whether the
    /// device is left locked; the caller unlocks it once the session runs. Leaves the preset in charge when the
    /// device has no suitable format or cannot be locked.
    private func lockFormat(of device: AVCaptureDevice) -> Bool {
        Self.turnOffCenterStage()
        let formats = device.formats.map { f -> CameraFormatChoice.Format in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let codec = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let compressed = codec == kCMVideoCodecType_JPEG_OpenDML || codec == kCMVideoCodecType_JPEG || codec == kCMVideoCodecType_H264
            return .init(width: Int(d.width), height: Int(d.height),
                         maxRate: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0, compressed: compressed)
        }
        guard let index = CameraFormatChoice.pick(formats) else {
            onNote?("camera \(device.modelID): no format from 640x480 to 1280x720; using the preset")
            return false
        }
        do { try device.lockForConfiguration() } catch {
            onNote?("camera \(device.modelID) could not be configured (\(error.localizedDescription)); using the preset")
            return false
        }
        let format = device.formats[index]
        device.activeFormat = format
        let rate = CameraFormatChoice.rate(for: formats[index])
        // A fixed frame duration within a supported range: an unsupported one raises an exception, not an error.
        let wanted = CMTime(value: 1000, timescale: CMTimeScale((rate * 1000).rounded()))
        if format.videoSupportedFrameRateRanges.contains(where: {
            CMTimeCompare($0.minFrameDuration, wanted) <= 0 && CMTimeCompare(wanted, $0.maxFrameDuration) <= 0 }) {
            device.activeVideoMinFrameDuration = wanted
            device.activeVideoMaxFrameDuration = wanted
            onNote?("camera \(device.modelID): \(formats[index].width)x\(formats[index].height) locked at \(Int(rate.rounded())) fps")
        } else if let best = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            device.activeVideoMinFrameDuration = best.minFrameDuration
            device.activeVideoMaxFrameDuration = best.minFrameDuration
            onNote?("camera \(device.modelID): \(formats[index].width)x\(formats[index].height) locked at \(Int(best.maxFrameRate.rounded())) fps")
        }
        return true
    }

    /// Stops and releases the session. Queued behind any start in progress, so it never blocks the caller.
    /// With a token, only the session that start created is torn down: a superseded start must not stop a newer one.
    func stop(token: Int? = nil) {
        queue.async {
            if let token, token != self.activeToken { return }
            self.teardownOnQueue()
        }
    }

    private func teardownOnQueue() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let session else { return }
        self.session = nil
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
