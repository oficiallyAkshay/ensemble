import Testing
@testable import EnsembleCore

@Suite struct CameraChoicesTests {
    private let cameras = ["FaceTime HD Camera", "HD Pro Webcam C920"]

    @Test func automaticComesFirstThenEveryConnectedCamera() {
        let rows = CameraChoices.rows(connected: cameras, chosen: nil)
        #expect(rows.map(\.title) == ["Automatic", "FaceTime HD Camera", "HD Pro Webcam C920"])
        #expect(rows.filter { !$0.isConnected }.isEmpty)
    }

    @Test func automaticIsMarkedWhenNothingIsChosen() {
        let rows = CameraChoices.rows(connected: cameras, chosen: nil)
        #expect(rows.filter(\.isCurrent).map(\.name) == [nil])
    }

    @Test func theChosenCameraIsTheOnlyOneMarked() {
        let rows = CameraChoices.rows(connected: cameras, chosen: "HD Pro Webcam C920")
        #expect(rows.filter(\.isCurrent).map(\.name) == ["HD Pro Webcam C920"])
    }

    @Test func aChosenCameraThatIsNotConnectedStaysListedAndSaysSo() {
        let rows = CameraChoices.rows(connected: cameras, chosen: "Studio Display Camera")
        #expect(rows.map(\.title) == ["Automatic", "FaceTime HD Camera", "HD Pro Webcam C920", "Studio Display Camera"])
        let missing = rows.last
        #expect(missing?.isCurrent == true)
        #expect(missing?.isConnected == false)
        #expect(missing?.label == "Studio Display Camera (not connected)")
        #expect(rows.first?.isConnected == true)
    }

    @Test func noCamerasStillOffersAutomatic() {
        let rows = CameraChoices.rows(connected: [], chosen: nil)
        #expect(rows == [CameraChoice(name: nil, isCurrent: true, isConnected: true)])
    }

    @Test func pickingAnEntryStoresItsNameAndMovesTheMark() {
        var stored: String? = nil
        let before = CameraChoices.rows(connected: cameras, chosen: stored)
        stored = before[2].name
        #expect(stored == "HD Pro Webcam C920")
        let after = CameraChoices.rows(connected: cameras, chosen: stored)
        #expect(after.filter(\.isCurrent).map(\.name) == ["HD Pro Webcam C920"])
        stored = after[0].name
        #expect(stored == nil)
        #expect(CameraChoices.rows(connected: cameras, chosen: stored)[0].isCurrent)
    }

    private let desk: [(id: String, kind: CameraKind)] = [("phone", .other), ("builtin", .builtIn), ("webcam", .external)]

    @Test func automaticKeepsTheOldOrderWhenNothingIsCalibrated() {
        #expect(CameraChoices.automaticPick(desk, calibratedIDs: []) == 2)
        #expect(CameraChoices.automaticPick(Array(desk.prefix(2)), calibratedIDs: []) == 1)
        #expect(CameraChoices.automaticPick([desk[0]], calibratedIDs: []) == 0)
        #expect(CameraChoices.automaticPick([], calibratedIDs: ["webcam"]) == nil)
    }

    @Test func automaticPrefersACameraWithASavedCalibration() {
        #expect(CameraChoices.automaticPick(desk, calibratedIDs: ["builtin"]) == 1)
        #expect(CameraChoices.automaticPick(desk, calibratedIDs: ["phone"]) == 0)
    }

    @Test func amongCalibratedCamerasTheExternalOneStillWins() {
        #expect(CameraChoices.automaticPick(desk, calibratedIDs: ["builtin", "webcam"]) == 2)
    }

    @Test func aCalibratedCameraThatIsNotConnectedChangesNothing() {
        #expect(CameraChoices.automaticPick(desk, calibratedIDs: ["gone"]) == 2)
    }

    @Test func aCameraPluggedInLaterAppearsOnTheNextBuild() {
        let before = CameraChoices.rows(connected: ["FaceTime HD Camera"], chosen: nil)
        let after = CameraChoices.rows(connected: ["FaceTime HD Camera", "HD Pro Webcam C920"], chosen: nil)
        #expect(before.count == 2)
        #expect(after.map(\.title).contains("HD Pro Webcam C920"))
    }
}
