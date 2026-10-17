import Foundation
import Testing
@testable import EnsembleCore

@Suite struct LidMicrophoneTests {
    static func device(_ uid: String, _ name: String, _ transport: String) -> InputDevice {
        InputDevice(uid: uid, name: name, transport: LidMicrophone.code(transport))
    }
    static let builtIn = device("builtin", "MacBook Pro Microphone", "bltn")
    static let webcam = device("cam", "HD Pro Webcam C920", "usb ")
    static let display = device("disp", "Studio Display Microphone", "usb ")
    static let usbMic = device("usb", "Yeti Stereo Microphone", "usb ")
    static let headset = device("bt", "AirPods Pro", "blue")
    static let leHeadset = device("ble", "LE Headset", "blea")
    static let iPhone = device("phone", "Akshay's iPhone Microphone", "ccwl")
    static let usbPhone = device("phone2", "iPad Microphone", "usb ")
    static let aggregate = device("agg", "Aggregate Device", "grup")
    static let loopback = device("virt", "BlackHole 2ch", "virt")

    static func decide(_ devices: [InputDevice], default uid: String? = "builtin", lidClosed: Bool = true, enabled: Bool = true) -> LidMicrophone.Decision {
        LidMicrophone.decide(devices: devices, defaultUID: uid, lidClosed: lidClosed, enabled: enabled)
    }

    // MARK: Which devices count

    @Test func tiersFollowTransportAndName() {
        #expect(LidMicrophone.tier(Self.webcam) == .webcam)
        #expect(LidMicrophone.tier(Self.display) == .webcam)
        #expect(LidMicrophone.tier(Self.usbMic) == .wired)
        #expect(LidMicrophone.tier(Self.device("tb", "Audio Interface", "thun")) == .wired)
        #expect(LidMicrophone.tier(Self.headset) == .bluetooth)
        #expect(LidMicrophone.tier(Self.leHeadset) == .bluetooth)
    }

    @Test func builtInVirtualAggregateAndContinuityNeverCount() {
        for d in [Self.builtIn, Self.loopback, Self.aggregate, Self.iPhone, Self.usbPhone,
                  Self.device("air", "AirPlay", "airp"), Self.device("x", "Unknown", "unkn")] {
            #expect(LidMicrophone.tier(d) == nil, "\(d.name)")
        }
    }

    // MARK: The choice

    @Test func webcamIsChosenFirstWhateverTheListOrder() {
        let all = [Self.builtIn, Self.headset, Self.usbMic, Self.webcam, Self.aggregate, Self.loopback, Self.iPhone]
        #expect(Self.decide(all) == .switchTo(Self.webcam))
    }

    @Test func wiredBeatsBluetoothWhenThereIsNoWebcam() {
        #expect(Self.decide([Self.builtIn, Self.headset, Self.usbMic]) == .switchTo(Self.usbMic))
    }

    @Test func onlyBluetoothIsUsedLast() {
        #expect(Self.decide([Self.builtIn, Self.headset]) == .switchTo(Self.headset))
    }

    @Test func onlyAnIPhoneChangesNothingAndSaysNoMicrophone() {
        #expect(Self.decide([Self.builtIn, Self.iPhone]) == .noMicrophone)
    }

    @Test func onlyVirtualOrAggregateSaysNoMicrophone() {
        #expect(Self.decide([Self.builtIn, Self.loopback, Self.aggregate]) == .noMicrophone)
    }

    @Test func noOtherInputSaysNoMicrophone() {
        #expect(Self.decide([Self.builtIn]) == .noMicrophone)
    }

    @Test func aDefaultThatAlreadyWorksIsLeftAlone() {
        #expect(Self.decide([Self.builtIn, Self.webcam, Self.headset], default: "bt") == .unchanged)
    }

    @Test func aVirtualOrContinuityDefaultIsMovedToARealInput() {
        #expect(Self.decide([Self.builtIn, Self.loopback, Self.webcam], default: "virt") == .switchTo(Self.webcam))
        #expect(Self.decide([Self.builtIn, Self.iPhone, Self.webcam], default: "phone") == .switchTo(Self.webcam))
    }

    @Test func noDefaultAtAllIsMovedToARealInput() {
        #expect(Self.decide([Self.builtIn, Self.webcam], default: nil) == .switchTo(Self.webcam))
    }

    @Test func lidOpenTouchesNothing() {
        #expect(Self.decide([Self.builtIn, Self.webcam], lidClosed: false) == .unchanged)
        #expect(Self.decide([Self.builtIn], lidClosed: false) == .unchanged)
    }

    @Test func settingOffTouchesNothing() {
        #expect(Self.decide([Self.builtIn, Self.webcam], enabled: false) == .unchanged)
        #expect(Self.decide([Self.builtIn], enabled: false) == .unchanged)
    }

    @Test func aMacWithoutABuiltInMicrophoneIsNeverRefused() {
        #expect(Self.decide([Self.loopback], default: "virt") == .unchanged)
    }

    // MARK: Putting it back

    static let change = LidMicrophone.Change(fromUID: "builtin", toUID: "cam")
    static func restore(_ change: LidMicrophone.Change? = change, current: String? = "cam", uids: [String] = ["builtin", "cam"],
                        lidClosed: Bool = false, enabled: Bool = true, idle: Bool = true) -> LidMicrophone.Restore {
        LidMicrophone.restore(change, currentUID: current, deviceUIDs: uids, lidClosed: lidClosed, enabled: enabled, idle: idle)
    }

    @Test func lidOpenPutsTheOldDefaultBack() {
        #expect(Self.restore() == .restore("builtin"))
    }

    @Test func lidStillClosedKeepsIt() {
        #expect(Self.restore(lidClosed: true) == .keep)
    }

    @Test func settingTurnedOffPutsTheOldDefaultBackEvenWithTheLidClosed() {
        #expect(Self.restore(lidClosed: true, enabled: false) == .restore("builtin"))
    }

    @Test func aDefaultHeChoseMeanwhileIsLeftAloneAndForgotten() {
        #expect(Self.restore(current: "usb") == .forget)
        #expect(Self.restore(current: "usb", lidClosed: true) == .forget)
        #expect(Self.restore(current: nil) == .forget)
    }

    @Test func aRestoreNeverHappensDuringADictation() {
        #expect(Self.restore(idle: false) == .keep)
        #expect(Self.restore(idle: true) == .restore("builtin"))
    }

    @Test func aPreviousDeviceThatIsGoneIsForgotten() {
        #expect(Self.restore(uids: ["cam"]) == .forget)
    }

    @Test func nothingChangedMeansNothingToRestore() {
        #expect(Self.restore(nil) == .keep)
    }
}
