import CoreAudio
import EnsembleCore
import Foundation

/// Applies `LidMicrophone`: with the lid closed the built-in microphone hears nothing but can stay the Mac's default
/// input, so right before a dictation starts the default moves to a microphone that works, and when the lid opens
/// (or the setting goes off) the old default comes back. Never mid-dictation: the dictation safety layer ends a
/// dictation whose input device changed, and a change made here happens only while Claude's microphone is off and
/// before the dictation's safety record is written. CoreAudio is read polled and off the main thread, as elsewhere.
@MainActor
final class MicrophoneSwitcher {
    private struct Snapshot: Sendable {
        var devices: [InputDevice]
        var defaultUID: String?
        var lidClosed: Bool
    }

    private let settings: SettingsStore
    private let overlay: OverlayController
    /// No dictation is starting, running or stopping (wired by the Coordinator).
    private let isIdle: () -> Bool
    /// What this switcher changed and not yet put back. Kept in memory only: nothing about audio goes to disk.
    private var change: LidMicrophone.Change?
    private var restoring = false

    init(settings: SettingsStore, overlay: OverlayController, isIdle: @escaping () -> Bool) {
        self.settings = settings
        self.overlay = overlay
        self.isIdle = isIdle
    }

    nonisolated private static func snapshot() -> Snapshot? {
        guard let devices = CoreAudioInput.allInputDevices() else { return nil }
        let current = CoreAudioInput.defaultInputDevice().flatMap { CoreAudioInput.deviceUID($0) }
        return Snapshot(devices: devices, defaultUID: current, lidClosed: ScreenFacts.lidClosed() ?? false)
    }

    /// Sets the default input and reads it back; macOS can take a moment to settle on a Bluetooth device.
    nonisolated private static func setAndConfirm(uid: String) -> Bool {
        guard let id = CoreAudioInput.device(withUID: uid), CoreAudioInput.setDefaultInputDevice(id) else { return false }
        for _ in 0..<10 {
            if CoreAudioInput.defaultInputDevice().flatMap({ CoreAudioInput.deviceUID($0) }) == uid { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Right before a dictation starts. Returns why it must not start, or nil.
    func prepare() async -> String? {
        guard settings.useAnotherMicrophoneWhenLidClosed else { return nil }
        // A restore that began a moment ago finishes first, so the two never change the input against each other.
        for _ in 0..<40 where restoring { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let snap = await Task.detached(operation: { Self.snapshot() }).value else { return nil }
        switch LidMicrophone.decide(devices: snap.devices, defaultUID: snap.defaultUID, lidClosed: snap.lidClosed, enabled: true) {
        case .unchanged:
            return nil
        case .noMicrophone:
            EnsembleLog.write("lid closed and no usable microphone; dictation not started")
            return "No microphone while the lid is closed"
        case .switchTo(let device):
            let uid = device.uid
            guard await Task.detached(operation: { Self.setAndConfirm(uid: uid) }).value else {
                EnsembleLog.write("could not move the default microphone to \(device.name); dictation not started")
                return "Could not switch to \(device.name) as the microphone"
            }
            change = snap.defaultUID.map { LidMicrophone.Change(fromUID: $0, toUID: uid) }
            EnsembleLog.write("lid closed: default microphone moved to \(device.name)")
            overlay.showBanner(title: "Microphone", body: "Using \(device.name) while the lid is closed", style: .info, seconds: 2.5)
            return nil
        }
    }

    /// From the 1 s check: puts the old default back once the lid is open (or the setting is off), and forgets the
    /// change when he picked another input meanwhile. Waits for an idle moment.
    func restoreIfNeeded() {
        guard let pending = change, !restoring else { return }
        restoring = true
        Task { @MainActor in
            defer { self.restoring = false }
            guard let snap = await Task.detached(operation: { Self.snapshot() }).value, self.change == pending else { return }
            switch LidMicrophone.restore(pending, currentUID: snap.defaultUID, deviceUIDs: snap.devices.map(\.uid),
                                         lidClosed: snap.lidClosed, enabled: self.settings.useAnotherMicrophoneWhenLidClosed,
                                         idle: self.isIdle()) {
            case .keep:
                break
            case .forget:
                self.change = nil
                EnsembleLog.write("default microphone changed by someone else or gone; nothing to put back")
            case .restore(let uid):
                let name = snap.devices.first { $0.uid == uid }?.name ?? ""
                if await Task.detached(operation: { Self.setAndConfirm(uid: uid) }).value {
                    self.change = nil
                    EnsembleLog.write("default microphone put back to \(name)")
                } else {
                    EnsembleLog.write("could not put the default microphone back to \(name); trying again")
                }
            }
        }
    }

    /// Quit path: puts the old default back at once if it is still the one this app set.
    func restoreNow() {
        guard let pending = change else { return }
        change = nil
        guard let snap = Self.snapshot(), snap.defaultUID == pending.toUID,
              snap.devices.contains(where: { $0.uid == pending.fromUID }) else { return }
        if Self.setAndConfirm(uid: pending.fromUID) { EnsembleLog.write("default microphone put back at quit") }
    }
}
