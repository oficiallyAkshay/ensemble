import Foundation

/// An audio input as CoreAudio lists it. `transport` is the device's four-character transport code.
public struct InputDevice: Equatable, Sendable {
    public var uid: String
    public var name: String
    public var transport: UInt32

    public init(uid: String, name: String, transport: UInt32) {
        self.uid = uid; self.name = name; self.transport = transport
    }
}

/// With the lid closed the built-in microphone hears nothing but can stay the Mac's default input. This chooses the
/// input to move the default to just before a dictation starts, and when to put the old default back. Only the
/// Coordinator applies it.
public enum LidMicrophone {
    /// Best first: the webcam's (or display's) microphone, other wired inputs, then a Bluetooth headset, last because
    /// selecting its microphone drops the headset to the low-quality call profile.
    public enum Tier: Int, Comparable, Sendable {
        case webcam, wired, bluetooth
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static let builtIn = code("bltn")
    static let bluetooth: Set<UInt32> = [code("blue"), code("blea")]
    static let wired: Set<UInt32> = [code("usb "), code("1394"), code("thun"), code("dprt"), code("pci ")]
    static let cameraWords = ["webcam", "camera", "cam", "facetime", "brio", "display"]

    /// nil: not usable with the lid closed. The built-in microphone, virtual and aggregate devices, AirPlay and the
    /// iPhone or iPad Continuity microphone are not wired or Bluetooth hardware inputs, so none of them gets a tier.
    public static func tier(_ d: InputDevice) -> Tier? {
        let name = d.name.lowercased()
        if name.contains("iphone") || name.contains("ipad") { return nil }
        if bluetooth.contains(d.transport) { return .bluetooth }
        guard wired.contains(d.transport) else { return nil }
        return cameraWords.contains(where: name.contains) ? .webcam : .wired
    }

    public enum Decision: Equatable, Sendable {
        case unchanged
        case switchTo(InputDevice)
        case noMicrophone
    }

    /// What to do right before a dictation starts. Nothing with the setting off, the lid open, or no built-in
    /// microphone to lose (a desktop Mac), and nothing when the default already is a usable input.
    public static func decide(devices: [InputDevice], defaultUID: String?, lidClosed: Bool, enabled: Bool) -> Decision {
        guard enabled, lidClosed, devices.contains(where: { $0.transport == builtIn }) else { return .unchanged }
        if let current = devices.first(where: { $0.uid == defaultUID }), tier(current) != nil { return .unchanged }
        let best = devices.compactMap { d in tier(d).map { (d, $0) } }.min { $0.1 < $1.1 }
        return best.map { .switchTo($0.0) } ?? .noMicrophone
    }

    /// What Ensemble changed: the default was `fromUID`, and Ensemble set it to `toUID`.
    public struct Change: Equatable, Sendable {
        public var fromUID: String
        public var toUID: String
        public init(fromUID: String, toUID: String) { self.fromUID = fromUID; self.toUID = toUID }
    }

    public enum Restore: Equatable, Sendable {
        case keep
        case forget
        case restore(String)
    }

    /// Whether to put the old default back. A default that is no longer the one Ensemble set was changed by him (or
    /// the device went away): the record is dropped and nothing is touched. The restore waits for `idle` (no
    /// dictation starting, running or stopping), since a changed input mid-dictation stops that dictation.
    public static func restore(_ change: Change?, currentUID: String?, deviceUIDs: [String],
                               lidClosed: Bool, enabled: Bool, idle: Bool) -> Restore {
        guard let change else { return .keep }
        if currentUID != change.toUID { return .forget }
        if lidClosed && enabled { return .keep }
        if !idle { return .keep }
        return deviceUIDs.contains(change.fromUID) ? .restore(change.fromUID) : .forget
    }
}
