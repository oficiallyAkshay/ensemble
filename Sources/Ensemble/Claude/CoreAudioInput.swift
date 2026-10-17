import AppKit
import CoreAudio
import EnsembleCore
import Foundation

/// One entry of the CoreAudio per-process object list (macOS 14.2+).
struct AudioProcess: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningInput: Bool
    var isRunningOutput: Bool
}

/// Polling reads of who is capturing audio, plus the input-device mute controls used by the safety layer.
/// Listeners are deliberately not used: they are unreliable on macOS 26, so callers poll.
enum CoreAudioInput {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func uint32(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var a = addr
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func objectIDs(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID]? {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        if count == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: Processes

    /// nil = the list could not be read at all (distinct from an empty list).
    static func processes() -> [AudioProcess]? {
        guard let ids = objectIDs(system, address(kAudioHardwarePropertyProcessObjectList)) else { return nil }
        var result: [AudioProcess] = []
        for id in ids {
            guard let pid = uint32(id, address(kAudioProcessPropertyPID)) else { continue }
            let bundle = string(id, address(kAudioProcessPropertyBundleID)) ?? ""
            let input = uint32(id, address(kAudioProcessPropertyIsRunningInput)) ?? 0
            let output = uint32(id, address(kAudioProcessPropertyIsRunningOutput)) ?? 0
            result.append(AudioProcess(objectID: id, pid: pid_t(pid), bundleID: bundle,
                                       isRunningInput: input != 0, isRunningOutput: output != 0))
        }
        return result
    }

    /// Devices a process object is using for input, as reported by CoreAudio.
    static func inputDevices(of process: AudioProcess) -> [AudioObjectID] {
        objectIDs(process.objectID, address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)) ?? []
    }

    // MARK: Devices

    static func defaultInputDevice() -> AudioObjectID? {
        guard let id = uint32(system, address(kAudioHardwarePropertyDefaultInputDevice)), id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceName(_ id: AudioObjectID) -> String? { string(id, address(kAudioObjectPropertyName)) }
    static func deviceUID(_ id: AudioObjectID) -> String? { string(id, address(kAudioDevicePropertyDeviceUID)) }

    static func device(withUID uid: String) -> AudioObjectID? {
        guard let all = objectIDs(system, address(kAudioHardwarePropertyDevices)) else { return nil }
        return all.first { deviceUID($0) == uid }
    }

    /// Every device that has an input stream, nil when the device list cannot be read.
    static func allInputDevices() -> [InputDevice]? {
        guard let all = objectIDs(system, address(kAudioHardwarePropertyDevices)) else { return nil }
        return all.compactMap { id in
            guard let streams = objectIDs(id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)), !streams.isEmpty,
                  let uid = deviceUID(id) else { return nil }
            return InputDevice(uid: uid, name: deviceName(id) ?? "", transport: uint32(id, address(kAudioDevicePropertyTransportType)) ?? 0)
        }
    }

    /// The same setting System Settings, Sound, Input changes. True when macOS accepted the write.
    static func setDefaultInputDevice(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    // MARK: Mute

    private static func inputAddr(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        address(selector, scope: kAudioDevicePropertyScopeInput, element: element)
    }

    /// Elements that carry the property: the master element if present, otherwise channels 1...n.
    private static func controlElements(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        var master = inputAddr(selector, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &master) { return [kAudioObjectPropertyElementMain] }
        var found: [AudioObjectPropertyElement] = []
        for ch in 1...8 {
            var a = inputAddr(selector, element: AudioObjectPropertyElement(ch))
            if AudioObjectHasProperty(id, &a) { found.append(AudioObjectPropertyElement(ch)) }
        }
        return found
    }

    private static func settable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        let elements = controlElements(id, selector)
        if elements.isEmpty { return false }
        for e in elements {
            var a = inputAddr(selector, element: e)
            var s: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &a, &s) != noErr || !s.boolValue { return false }
        }
        return true
    }

    static func muteIsSettable(_ id: AudioObjectID) -> Bool { settable(id, kAudioDevicePropertyMute) }
    static func volumeIsSettable(_ id: AudioObjectID) -> Bool { settable(id, kAudioDevicePropertyVolumeScalar) }

    /// True when every muteable element is muted; nil when the device has no readable mute control.
    static func isMuted(_ id: AudioObjectID) -> Bool? {
        let elements = controlElements(id, kAudioDevicePropertyMute)
        if elements.isEmpty { return nil }
        var all = true
        for e in elements {
            guard let v = uint32(id, inputAddr(kAudioDevicePropertyMute, element: e)) else { return nil }
            if v == 0 { all = false }
        }
        return all
    }

    @discardableResult
    static func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        guard muteIsSettable(id) else { return false }
        var ok = true
        for e in controlElements(id, kAudioDevicePropertyMute) {
            var a = inputAddr(kAudioDevicePropertyMute, element: e)
            var v: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) != noErr { ok = false }
        }
        return ok
    }

    /// Mean input volume across elements; nil when unreadable.
    static func volume(_ id: AudioObjectID) -> Float32? {
        let elements = controlElements(id, kAudioDevicePropertyVolumeScalar)
        if elements.isEmpty { return nil }
        var sum: Float32 = 0
        for e in elements {
            var a = inputAddr(kAudioDevicePropertyVolumeScalar, element: e)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
            sum += v
        }
        return sum / Float32(elements.count)
    }

    @discardableResult
    static func setVolume(_ id: AudioObjectID, _ volume: Float32) -> Bool {
        guard volumeIsSettable(id) else { return false }
        var ok = true
        for e in controlElements(id, kAudioDevicePropertyVolumeScalar) {
            var a = inputAddr(kAudioDevicePropertyVolumeScalar, element: e)
            var v = volume
            if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) != noErr { ok = false }
        }
        return ok
    }
}

/// Process-tree helpers.
enum ProcessInfoLookup {
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func isDescendant(_ pid: pid_t, ofAny roots: Set<pid_t>) -> Bool {
        var cur = pid
        for _ in 0..<24 {
            if roots.contains(cur) { return true }
            guard let parent = parentPID(of: cur), parent > 1, parent != cur else { return false }
            cur = parent
        }
        return false
    }

    static func name(of pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}
